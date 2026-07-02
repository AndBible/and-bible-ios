import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func elementHasUsableFrame(_ element: XCUIElement) -> Bool {
        guard element.exists else {
            return false
        }
        return elementFrameIsUsable(element.frame)
    }

    /**
     Returns true when one already sampled frame is finite and usable for coordinate taps.
     *
     * XCTest can occasionally expose frames whose stored origin and size are finite but whose
     * derived edges or midpoint overflow. Coordinate helpers synthesize taps from those derived
     * values, so the guard rejects the entire frame before any caller reaches XCTest's event path.
     */
    func elementFrameIsUsable(_ frame: CGRect) -> Bool {
        return !frame.isNull &&
            !frame.isEmpty &&
            frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.minX.isFinite &&
            frame.minY.isFinite &&
            frame.midX.isFinite &&
            frame.midY.isFinite &&
            frame.maxX.isFinite &&
            frame.maxY.isFinite
    }

    /**
     Samples hittability only after the element exposes a usable frame.
     */
    func isElementHittable(_ element: XCUIElement) -> Bool {
        elementHasUsableFrame(element) && element.isHittable
    }

    /**
     Waits for one live XCUI element to become hittable.
     *
     * - Parameters:
     *   - element: Resolved XCUI element expected to expose a tappable accessibility surface.
     *   - timeout: Maximum number of seconds to poll.
     * - Returns: `true` when XCTest reports the element as hittable before the timeout.
     * - Side effects:
     *   - repeatedly samples the element while allowing pending UI transitions to settle
     * - Failure modes: This helper does not fail directly.
     */
    func waitForElementToBecomeHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isElementHittable(element) {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0, !element.exists {
                _ = element.waitForExistence(timeout: min(0.2, remaining))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return isElementHittable(element)
    }

    /**
     Waits for one resolved element to become tappable, then uses XCTest's native tap path.
     *
     * - Parameters:
     *   - element: Resolved XCUI element that should be tapped.
     *   - timeout: Maximum number of seconds to wait for the element to become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the live element to appear and uses XCTest's native `tap()` path once the
     *     simulator reports the element as hittable
     * - Failure modes:
     *   - records an XCTest failure if the element never appears
     *   - records an XCTest failure if the element never becomes hittable
     */
    func tapElementReliably(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if waitForElementToBecomeHittable(element, timeout: timeout) {
            element.tap()
            return
        }

        let exists = element.exists || element.waitForExistence(timeout: min(timeout, 1))
        XCTAssertTrue(
            exists,
            "Expected element '\(element.identifier)' to exist before tapping within \(timeout) seconds.",
            file: file,
            line: line
        )
        guard exists else {
            return
        }
        if elementHasUsableFrame(element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        XCTFail(
            "Expected element '\(element.identifier)' to expose a usable frame before tapping within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /// Taps an element when it is currently actionable, falling back to its center coordinate.
    @discardableResult
    func tapElementIfPossible(
        _ element: XCUIElement,
        timeout: TimeInterval = 1
    ) -> Bool {
        if waitForElementToBecomeHittable(element, timeout: timeout) {
            element.tap()
            return true
        }
        if elementHasUsableFrame(element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        return false
    }

    /**
     Reveals one SwiftUI trailing swipe action by repeating the real horizontal row gesture.

     XCTest's built-in `swipeLeft()` can intermittently stop short on CI-hosted SwiftUI lists even
     though the user-visible row supports swipe actions. This helper does not invoke the action
     directly; it retries the same trailing-swipe affordance and falls back to a precise coordinate
     drag across the row until the real action button is exposed.
     *
     * - Parameters:
     *   - actionIdentifier: Accessibility identifier of the expected swipe action button.
     *   - row: Visible row that owns the trailing swipe action.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep attempting the gesture.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: performs horizontal swipe gestures against `row` and polls the live
     *   accessibility hierarchy for `actionIdentifier`.
     * - Failure modes: records an XCTest failure when the action never becomes visible.
     */
    func revealTrailingSwipeAction(
        _ actionIdentifier: String,
        for row: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if waitForResolvedElementAppearance(actionIdentifier, in: app, timeout: 0.2) {
                return
            }

            if waitForElementToBecomeHittable(row, timeout: 0.3) {
                row.swipeLeft()
            }
            if waitForResolvedElementAppearance(actionIdentifier, in: app, timeout: 0.5) {
                return
            }

            if elementHasUsableFrame(row) {
                let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5))
                let finish = row.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: finish)
            }
            if waitForResolvedElementAppearance(actionIdentifier, in: app, timeout: 0.5) {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            resolvedElement(actionIdentifier, in: app) != nil,
            "Expected trailing swipe action '\(actionIdentifier)' to appear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Returns whether one resolved element exposes a visible leading-edge tap point within a
     container viewport.
     *
     * - Parameters:
     *   - element: Live XCUI element that may be partially clipped by the container.
     *   - container: Scrollable ancestor whose visible bounds should contain the tap point.
     * - Returns: `true` when the element exposes a stable tap point within the container viewport.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func isElementVisible(
        _ element: XCUIElement,
        within container: XCUIElement
    ) -> Bool {
        guard element.exists, !element.frame.isEmpty else {
            return false
        }
        guard container.exists, !container.frame.isEmpty else {
            return true
        }

        let minimumVisibleHeight = min(max(24, element.frame.height * 0.5), element.frame.height)
        let minimumVisibleWidth = min(max(40, element.frame.width * 0.3), element.frame.width)
        let verticalInset = min(16, max(0, (container.frame.height - minimumVisibleHeight) / 2))
        let visibleFrame = container.frame.insetBy(dx: 0, dy: verticalInset)
        let intersection = visibleFrame.intersection(element.frame)
        guard !intersection.isNull else {
            return false
        }
        return intersection.height >= minimumVisibleHeight &&
            intersection.width >= minimumVisibleWidth
    }

    /**
     Taps one deterministic segment within a visible segmented control by geometry instead of child
     button queries, which SwiftUI does not expose consistently across XCTest runtimes.
     *
     * - Parameters:
     *   - control: Segmented control exporting the target segments.
     *   - index: Zero-based segment index to tap.
     *   - segmentCount: Total number of visible segments in the control.
     *   - timeout: Maximum number of seconds to wait for the control to expose a stable frame.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the segmented control to expose a non-empty frame, then taps the requested
     *     segment center directly
     * - Failure modes:
     *   - records an XCTest failure if the control never appears or the requested segment index is
     *     out of range
     */
    func tapSegmentedControlSegment(
        _ control: XCUIElement,
        index: Int,
        segmentCount: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            index >= 0 && index < segmentCount,
            "Expected segmented control segment index \(index) to be within 0..<\(segmentCount).",
            file: file,
            line: line
        )
        guard index >= 0 && index < segmentCount else {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !control.frame.isEmpty {
                let dx = (CGFloat(index) + 0.5) / CGFloat(segmentCount)
                control.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                _ = control.waitForExistence(timeout: min(0.2, remaining))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            !control.frame.isEmpty,
            "Expected segmented control '\(control.identifier)' to expose a non-empty frame before tapping segment \(index) within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /// Shared geometry constants for the Search word-mode segmented control.
    enum SearchWordModeControl {
        static let segmentCount = 3
    }

    /// Shared normalized screen coordinates used by no-query keyboard dismissal helpers.
    enum KeyboardDismissalCoordinate {
        static let focusDismissal = CGVector(dx: 0.5, dy: 0.08)
        static let softwareReturnKey = CGVector(dx: 0.92, dy: 0.93)
    }

    /**
     Dismisses the software keyboard through a coordinate tap outside the focused field.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - taps a stable non-control area near the top of the app window
     * - Failure modes:
     *   - silently leaves focus unchanged when the active control refuses to resign focus
     */
    func dismissKeyboardIfPresent(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: KeyboardDismissalCoordinate.focusDismissal).tap()
    }

    /**
     Dismisses the software keyboard immediately after a known text-entry edit.
     *
     This path intentionally avoids `app.keyboards`, app-wide focused-field queries, and
     element-scoped `hasKeyboardFocus` predicates. Hosted XCTest has wedged while resolving stale
     SwiftUI text-field snapshots immediately after typing, so the helper uses the same stable
     coordinate dismissal path as other no-query keyboard flows.
     *
     - Parameters:
     *   - element: Text-entry control that just received keyboard input. Kept for call-site clarity;
     *     the helper does not query it after typing.
     *   - app: Running application under test.
     * - Side effects:
     *   - taps the software keyboard return-key region
     *   - taps a stable non-control area near the top of the app window
     * - Failure modes:
     *   - silently leaves focus unchanged when the active control refuses to resign focus
     */
    func dismissKeyboardAfterFocusedTextEntry(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        _ = element
        app.coordinate(withNormalizedOffset: KeyboardDismissalCoordinate.softwareReturnKey).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        dismissKeyboardIfPresent(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    /**
     Waits for the currently presented alert text field to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first alert-owned text field.
     * - Side effects:
     *   - waits for a live alert, then resolves its native text field instead of the broader app
     *     hierarchy
     * - Failure modes:
     *   - records an XCTest failure if no alert text field appears within the timeout
     */
    func requireAlertTextField(
        in app: XCUIApplication,
        titles: [String] = [],
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: timeout),
            "Expected an alert with a text field within \(timeout) seconds.",
            file: file,
            line: line
        )

        let normalizedTitles = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let textField = firstExistingElement(
                modalTextFieldCandidates(in: alert, titles: normalizedTitles),
                timeout: 0.2
            ) {
                return textField
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let textField = alert.textFields.element(boundBy: 0)
        XCTAssertTrue(
            textField.exists,
            "Expected the presented alert to expose a text field within \(timeout) seconds.",
            file: file,
            line: line
        )
        return textField
    }

    /**
     Taps one native alert button and waits for the alert to disappear before continuing.
     *
     * - Parameters:
     *   - title: Visible button title expected inside the currently presented alert.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the button and dismissal.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the live alert button, taps it, and blocks until the alert no longer exists
     * - Failure modes:
     *   - records an XCTest failure if the alert button never appears or the alert does not
     *     dismiss after the tap
     */
    func tapAlertButton(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: timeout),
            "Expected an alert before tapping '\(title)'.",
            file: file,
            line: line
        )
        let button = alert.buttons[title].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected alert button '\(title)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(button, timeout: timeout, file: file, line: line)

        let dismissedPredicate = NSPredicate(format: "exists == false")
        expectation(for: dismissedPredicate, evaluatedWith: alert)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            alert.exists,
            "Expected the alert to dismiss after tapping '\(title)'.",
            file: file,
            line: line
        )
    }

    /**
     Performs a direct top-edge drag to dismiss a presented sheet.
     *
     * - Parameter element: Visible sheet-root element that should respond to the dismissal drag.
     * - Side effects:
     *   - drags from near the sheet's top edge toward the bottom of the screen, which dismisses
     *     the sheet instead of scrolling the sheet content
     * - Failure modes:
     *   - records an XCTest failure if the element never exposes a usable frame
     */
    func dismissSheetByDraggingDown(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element.frame.isEmpty,
            "Expected sheet element '\(element.identifier)' to expose a non-empty frame before dismissal.",
            file: file,
            line: line
        )
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        let finish = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: finish)
    }

    /**
     Waits for one previously resolved element to disappear from the live hierarchy.
     *
     * - Parameters:
     *   - element: Previously visible element expected to disappear.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - blocks the current test until the element no longer exists
     * - Failure modes:
     *   - records an XCTest failure if the element remains visible after the timeout
     */
    func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            element.exists,
            "Expected element '\(element.identifier)' to disappear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Dismisses one lingering alert through its cancel button when the alert is still present.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the alert/cancel button.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the visible cancel button only when an alert is still present after a flow that
     *     should already have dismissed it
     * - Failure modes:
     *   - records an XCTest failure if a presented alert exposes no cancel button or refuses to
     *     dismiss after the cancel tap
     */
    func dismissAlertIfPresent(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alert = app.alerts.firstMatch
        guard alert.exists || alert.waitForExistence(timeout: min(1, timeout)) else {
            return
        }

        let cancelButton = alert.buttons["Cancel"].firstMatch
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: timeout),
            "Expected lingering alert '\(alert.label)' to expose a Cancel button within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(cancelButton, timeout: timeout, file: file, line: line)
        waitForElementToDisappear(alert, timeout: timeout, file: file, line: line)
    }

    /**
     Closes the workspace selector when switching rows did not dismiss it automatically.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the selector to dismiss on its own after a workspace switch
     *   - taps the real toolbar Done button when the selector remains visible
     * - Failure modes:
     *   - records an XCTest failure if the selector is still visible after the timeout expires
     */
    func dismissWorkspaceSelectorIfStillPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selector = unresolvedElement("workspaceSelectorScreen", in: app)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !selector.exists {
                return
            }

            let doneButton = app.buttons["workspaceSelectorDoneButton"].firstMatch
            if doneButton.exists || doneButton.waitForExistence(timeout: 0.5) {
                tapElementReliably(doneButton, timeout: 5, file: file, line: line)
                if selector.exists {
                    waitForElementToDisappear(selector, timeout: min(10, deadline.timeIntervalSinceNow), file: file, line: line)
                }
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        XCTFail(
            "Expected the workspace selector to dismiss within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /// Returns the first visible candidate from one explicit XCUI query list.
    func firstVisibleCandidate(
        from candidates: [XCUIElement],
        waitTimeout: TimeInterval = 0
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(waitTimeout)
        repeat {
            for candidate in candidates where candidate.exists {
                if isElementHittable(candidate) || elementHasUsableFrame(candidate) {
                    return candidate
                }
            }
            if waitTimeout <= 0 {
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
    }

    /// Resolves the bookmark-list search field through explicit titled queries.
    func requireBookmarkListSearchField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let candidates = [
            app.textFields["bookmarkListSearchField"].firstMatch,
            app.searchFields["Search bookmarks"].firstMatch,
            app.textFields["Search bookmarks"].firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let field = firstVisibleCandidate(from: candidates, waitTimeout: 0.2) {
                return field
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected bookmark search field to exist.",
            file: file,
            line: line
        )
        return candidates.first ?? app.searchFields["Search bookmarks"].firstMatch
    }

    /// Returns explicit Search input candidates without falling back to broad first-match scans.
    func searchInputCandidates(in app: XCUIApplication) -> [XCUIElement] {
        elementCandidates(for: "searchQueryField", in: app)
    }

    /// Returns the first visible Search input candidate.
    func resolveVisibleSearchInput(
        in app: XCUIApplication,
        waitTimeout: TimeInterval = 0
    ) -> XCUIElement? {
        firstVisibleCandidate(from: searchInputCandidates(in: app), waitTimeout: waitTimeout)
    }

    /**
     Resolves the visible text-entry control for Search across system search-field variants.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait while revealing and re-querying the search control.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first visible Search input control exposed as either a `SearchField` or
     *   generic `TextField`.
     * - Side effects:
     *   - re-queries the Search hierarchy across a few downward swipes to reveal system search UI
     *     variants that are not immediately visible in hosted simulators
     * - Failure modes:
     *   - records an XCTest failure if neither control type appears before the timeout expires
     */
    func requireSearchInput(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let field = resolveVisibleSearchInput(in: app, waitTimeout: 0.2) {
                return field
            }
            revealSearchControls(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail(
            "Expected Search text field to exist.",
            file: file,
            line: line
        )
        return resolveVisibleSearchInput(in: app) ?? unresolvedElement("searchQueryField", in: app)
    }

    /**
     Reads the current Search input value from a freshly resolved live field.
     *
     * - Parameter app: Running application under test.
     * - Returns: The current Search field value, or an empty string when no live Search field is
     *   currently exposed.
     * - Side effects:
     *   - re-queries the live Search field hierarchy instead of relying on a previously resolved
     *     XCUI element handle
     * - Failure modes:
     *   - returns an empty string when the Search input is temporarily absent or its value is not a
     *     string
     */
    func resolvedSearchInputValue(in app: XCUIApplication) -> String {
        if let candidate = resolveVisibleSearchInput(in: app) {
            return candidate.value as? String ?? ""
        }

        return ""
    }

    /**
     Resolves the visible Create button from Search's index prompt while excluding the root Search
     screen element that XCTest may misclassify as a button on some simulator runtimes.
     *
     * - Parameter app: Running application under test.
     * - Returns: The first real Create button candidate, or an unresolved query when none exists.
     * - Side effects:
     *   - queries the live XCUI hierarchy for buttons labeled `Create`
     * - Failure modes:
     *   - returns an unresolved fallback element when the prompt button is unavailable
     */
    func resolveSearchCreateIndexButton(in app: XCUIApplication) -> XCUIElement {
        let alertCreateButton = app.alerts.firstMatch.buttons["Create"].firstMatch
        if alertCreateButton.exists || alertCreateButton.waitForExistence(timeout: 0.5) {
            return alertCreateButton
        }

        let sheetCreateButton = app.sheets.firstMatch.buttons["Create"].firstMatch
        if sheetCreateButton.exists || sheetCreateButton.waitForExistence(timeout: 0.5) {
            return sheetCreateButton
        }

        let visibleCreateButton = app.buttons["Create"].firstMatch
        if visibleCreateButton.exists || visibleCreateButton.waitForExistence(timeout: 0.5) {
            return visibleCreateButton
        }

        return visibleCreateButton
    }

    /**
     Resolves the text field used by the Label Manager create-label alert.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The best available alert text field, preferring the explicit accessibility
     *   identifier when SwiftUI exposes it.
     * - Side effects:
     *   - waits for the alert to appear and then re-queries its text fields
     * - Failure modes:
     *   - records an XCTest failure if the create-label alert or its text field never appears
     */
    func requireLabelManagerNewLabelField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let field = resolveLabelCreationPromptTextField(in: app) {
                return field
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected element 'labelManagerNewLabelNameField' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        if let prompt = resolvedLabelCreationPrompt(in: app),
           let field = firstExistingElement(modalTextFieldCandidates(in: prompt, titles: ["Label name"]))
        {
            return field
        }
        return app.alerts.firstMatch.textFields.element(boundBy: 0)
    }

    /**
     Resolves the create action button shown by the Label Manager create-label alert.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The best available create button, preferring the explicit accessibility
     *   identifier when SwiftUI exposes it.
     * - Side effects:
     *   - waits for the alert to appear and then re-queries its action buttons
     * - Failure modes:
     *   - records an XCTest failure if the create button never appears
     */
    func requireLabelManagerCreateButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = resolveLabelCreationPromptCreateButton(in: app) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected element 'labelManagerCreateButton' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        if let prompt = resolvedLabelCreationPrompt(in: app),
           let button = firstExistingElement(modalButtonCandidates(in: prompt, titles: ["Create"]))
        {
            return button
        }
        return app.alerts.firstMatch.buttons["Create"].firstMatch
    }

    /**
     Waits for the Settings screen to expose at least one stable production control.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before giving up.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: `true` when Settings is ready for interaction, otherwise `false`.
     * - Side effects:
     *   - dismisses the language restart confirmation when it appears during navigation
     *   - polls the Settings screen for both the form root and stable row identifiers
     * - Failure modes: This helper does not fail directly.
     */
    func waitForSettingsReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let settingsForm = resolvedElement("settingsForm", in: app),
               settingsForm.exists,
               !settingsForm.frame.isEmpty
            {
                return true
            }

            if resolvedElement("settingsForm", in: app) != nil {
                return true
            }

            let alert = app.alerts.firstMatch
            let okButton = alert.buttons["OK"].firstMatch
            if alert.exists && okButton.exists && !okButton.frame.isEmpty {
                tapElementReliably(okButton, timeout: 2, file: file, line: line)
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Waits for the exported Settings screen state to contain one deterministic token.
     *
     * - Parameters:
     *   - expectedToken: Token expected inside the semicolon-delimited Settings screen state.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to poll before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly reads the production `settingsForm` accessibility value
     * - Failure modes:
     *   - records an XCTest failure if the requested token never appears before timeout
     */
    func waitForSettingsState(
        containing expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let state = settingsForm.value as? String, state.contains(expectedToken) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalState = settingsForm.value as? String ?? ""
        XCTFail(
            "Expected Settings state to contain '\(expectedToken)' within \(timeout) seconds. Last state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the My Notes screen title to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the My Notes title.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the My Notes title appears
     * - Failure modes:
     *   - records an XCTest failure if the native My Notes title never appears before timeout
     */
    func waitForMyNotesPresentation(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            requireElement("readerMyNotesTitle", in: app, timeout: timeout, file: file, line: line).exists,
            file: file,
            line: line
        )
    }

    /**
     Opens the current-passage My Notes pseudo-document through the production Choose Document flow.
     *
     * Android exposes My Notes in `ChooseDocument` as a `FakeBookFactory` pseudo-document while the
     * drawer My Documents row launches the app-owned My Documents manager. This helper intentionally
     * follows the chooser pseudo-document route so My Notes lifecycle tests do not preserve the old
     * iOS drawer deviation.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the chooser row and visible My Notes document.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
	     * - Side effects:
	     *   - opens the reader drawer, launches Choose Document, filters the Android-style chooser to
	     *     the `FakeBookFactory` `My Note` initials, selects that row, and waits for the
	     *     WebView-owned My Notes document to render
	     * - Failure modes:
	     *   - records an XCTest failure if the chooser, pseudo-document row, or My Notes state never
	     *     becomes visible
     */
	    func openMyNotesFromReader(
	        in app: XCUIApplication,
	        timeout: TimeInterval = 20,
	        file: StaticString = #filePath,
	        line: UInt = #line
	    ) {
	        tapReaderAction("readerChooseDocumentAction", in: app, timeout: timeout, file: file, line: line)
	        _ = requireElement("modulePickerScreen", in: app, timeout: timeout, file: file, line: line)
	        let searchField = requireElement("modulePickerSearchField", in: app, timeout: timeout, file: file, line: line)
	        replaceText(in: searchField, with: "My Note", placeholderHints: ["Search"])
	        tapElementReliably(
	            requireElement("modulePickerPseudoRow::myNotes", in: app, timeout: timeout, file: file, line: line),
	            timeout: timeout
	        )
        waitForMyNotesPresentation(in: app, timeout: timeout, file: file, line: line)
        waitForVisibleMyNotesState(
            containing: "myNotesVisible=true",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Waits for the reader's compact My Notes state export to contain one token.
     */
    func waitForMyNotesState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected My Notes state to contain '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for a compact My Notes export that is both visible and contains one token.
     */
    func waitForVisibleMyNotesState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { $0.contains("myNotesVisible=true") && $0.contains(token) },
            failureDescription: { finalValue in
                "Expected visible My Notes state to contain '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits until the My Notes editor opens or its UI-test edit mutation has already persisted.
     */
    func waitForVisibleMyNotesEditorActivation(
        orPersistedMarker marker: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { state in
                state.contains("myNotesVisible=true")
                    && (state.contains("myNotesEditing=true") || state.contains(marker))
            },
            failureDescription: { finalValue in
                "Expected visible My Notes editor activation or persisted marker '\(marker)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for the reader's compact My Notes state export to stop containing one token.
     */
    func waitForMyNotesState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { !$0.contains(token) },
            failureDescription: { finalValue in
                "Expected My Notes state to stop containing '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for a compact My Notes export that is visible and no longer contains one token.
     */
    func waitForVisibleMyNotesState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { $0.contains("myNotesVisible=true") && !$0.contains(token) },
            failureDescription: { finalValue in
                "Expected visible My Notes state to stop containing '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Resolves one accessibility-labelled My Notes control without recording an XCTest failure.
     */
    func optionalMyNotesWebControl(
        named label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let candidates = [
            app.webViews.buttons[label].firstMatch,
            app.webViews.links[label].firstMatch,
            app.webViews.otherElements[label].firstMatch,
            app.buttons[label].firstMatch,
            app.links[label].firstMatch,
            app.otherElements[label].firstMatch,
        ]
        return firstExistingDocumentWebControl(candidates, timeout: timeout)
    }

    /**
     Polls a small embedded-document candidate set using a shared timeout across all accessibility types.
     */
    func firstExistingDocumentWebControl(
        _ candidates: [XCUIElement],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            for candidate in candidates where candidate.exists && elementHasUsableFrame(candidate) {
                return candidate
            }
            for candidate in candidates where candidate.exists {
                return candidate
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let actionableCandidate = candidates.first(where: { $0.exists && elementHasUsableFrame($0) }) {
            return actionableCandidate
        }
        return candidates.first(where: { $0.exists })
    }

    /**
     Waits for a compact StudyPad export that is both visible and contains one token.
     */
    func waitForVisibleStudyPadState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "readerRenderedContentState",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) },
            success: { $0.contains("studyPadVisible=true") && $0.contains(token) },
            failureDescription: { finalValue in
                "Expected visible StudyPad state to contain '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Resolves one accessibility-labelled StudyPad control without recording an XCTest failure.
     */
    func optionalStudyPadWebControl(
        named label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let candidates = [
            app.webViews.buttons[label].firstMatch,
            app.webViews.links[label].firstMatch,
            app.webViews.otherElements[label].firstMatch,
            app.buttons[label].firstMatch,
            app.links[label].firstMatch,
            app.otherElements[label].firstMatch,
        ]
        return firstExistingDocumentWebControl(candidates, timeout: timeout)
    }

    /**
     Dismisses the bookmark list surface if the StudyPad handoff leaves it visible over the reader.

     - Parameters:
       - app: Running application that may still show the bookmark list.
       - timeout: Maximum number of seconds to spend on the close attempt.
     - Side effects:
       - taps the sheet Done button or destination back button when either is visible
     - Failure modes:
       - returns without failing when the bookmark list is not visible
     */
    func dismissBookmarkListIfVisible(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        guard bookmarkListSurfaceIsVisible(in: app) else {
            return
        }
        let doneButton = app.buttons["bookmarkListDoneButton"].firstMatch
        if tapElementIfPossible(doneButton, timeout: min(timeout, 2)) {
            _ = waitForBookmarkListDismissal(in: app, timeout: timeout)
            return
        }

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        _ = tapElementIfPossible(backButton, timeout: min(timeout, 2))
        _ = waitForBookmarkListDismissal(in: app, timeout: timeout)
    }

    /**
     Waits for the StudyPad screen title to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the StudyPad title.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the StudyPad title appears
     * - Failure modes:
     *   - records an XCTest failure if the native StudyPad title never appears before timeout
     */
    func waitForStudyPadPresentation(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            requireElement("readerStudyPadTitle", in: app, timeout: timeout, file: file, line: line).exists,
            file: file,
            line: line
        )
    }
}
