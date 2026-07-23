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
     Returns a stable, non-empty element name for XCTest wait diagnostics.
     *
     * - Parameter element: UI element whose identifier or label should describe the wait target.
     * - Returns: the accessibility identifier, visible label, or a generic placeholder.
     * - Side effects: none
     * - Failure modes: Falls back to a placeholder when XCTest exposes neither identifier nor label.
     */
    func uiTestElementDiagnosticName(_ element: XCUIElement) -> String {
        let identifier = element.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identifier.isEmpty {
            return identifier
        }

        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }

        return "unidentified UI element"
    }

    /**
     Waits for a UI-test condition through XCTest's predicate waiter.

     - Parameters:
       - description: Human-readable condition name used in XCTest diagnostics.
       - timeout: Maximum number of seconds to wait after an initial immediate probe.
       - condition: Predicate closure that reads current UI state and returns true once ready.
     - Returns: `true` when the condition succeeds immediately or before the timeout.
     - Side effects:
       - samples `condition` through `XCTNSPredicateExpectation` while XCTest waits
     - Failure modes: This helper does not fail directly.
     */
    @discardableResult
    func waitForUITestCondition(
        _ description: String,
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        if condition() {
            return true
        }
        guard timeout > 0 else {
            return false
        }

        let predicate = NSPredicate { _, _ in
            condition()
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = description
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed || condition()
    }

    /**
     Waits for one live XCUI element to become hittable.
     *
     * - Parameters:
     *   - element: Resolved XCUI element expected to expose a tappable accessibility surface.
     *   - timeout: Maximum number of seconds to poll.
     * - Returns: `true` when XCTest reports the element as hittable before the timeout.
     * - Side effects:
     *   - observes the element through XCTest's predicate waiter while pending UI transitions settle
     * - Failure modes: This helper does not fail directly.
     */
    func waitForElementToBecomeHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition(
            "Wait for \(uiTestElementDiagnosticName(element)) to become hittable",
            timeout: max(0, timeout)
        ) { [weak self] in
            self?.isElementHittable(element) ?? false
        }
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

        let predicate = NSPredicate(block: { _, _ in
            control.exists && !control.frame.isEmpty
        })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for segmented control frame"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result == .completed || (control.exists && !control.frame.isEmpty) {
            let dx = (CGFloat(index) + 0.5) / CGFloat(segmentCount)
            control.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            return
        }

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
     Resolves a button from either a system alert or an app-owned Android decision dialog.

     - Parameters:
       - title: Visible button title expected inside the currently presented decision surface.
       - app: Running application under test.
       - timeout: Maximum number of seconds to wait for a matching surface and button.
     - Returns: The owning decision surface and matching button, or `nil` after the bounded wait.
     - Side effects: Polls the accessibility hierarchy without activating controls.
     - Failure modes: Returns `nil` when no supported decision surface exposes the requested button.
     */
    func resolveDecisionDialogButton(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> (surface: XCUIElement, button: XCUIElement)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let systemAlert = app.alerts.firstMatch
            if systemAlert.exists {
                let button = systemAlert.buttons[title].firstMatch
                if button.exists {
                    return (systemAlert, button)
                }
            }

            let androidSurfaceIdentifiers = [
                "androidMyDocumentDecisionDialog",
                "androidModulePickerDecisionDialog",
                "androidReadingProgressDecisionDialog",
            ]
            let androidSurfaces = androidSurfaceIdentifiers.compactMap { identifier in
                resolvedElement(identifier, in: app)
            }
            for surface in androidSurfaces where surface.exists {
                let nestedButton = surface.buttons[title].firstMatch
                if nestedButton.exists {
                    return (surface, nestedButton)
                }

                // SwiftUI can flatten overlay controls beside their identified container in the
                // accessibility tree, so resolve the visible action from the application root.
                let flattenedButton = app.buttons[title].firstMatch
                if flattenedButton.exists, flattenedButton.isHittable {
                    return (surface, flattenedButton)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /**
     Taps one system-alert or Android decision-dialog button and waits for its surface to disappear.
     *
     * - Parameters:
     *   - title: Visible button title expected inside the currently presented alert.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the button and dismissal.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the live decision button, taps it, and blocks until its surface no longer exists
     * - Failure modes:
     *   - records an XCTest failure if the decision button never appears or the surface does not
     *     dismiss after the tap
     */
    func tapAlertButton(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let decision = resolveDecisionDialogButton(title, in: app, timeout: timeout) else {
            XCTFail(
                "Expected a system alert or Android decision dialog before tapping '\(title)'.",
                file: file,
                line: line
            )
            return
        }
        XCTAssertTrue(
            decision.button.exists,
            "Expected decision button '\(title)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(decision.button, timeout: timeout, file: file, line: line)

        let dismissedPredicate = NSPredicate(format: "exists == false")
        expectation(for: dismissedPredicate, evaluatedWith: decision.surface)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            decision.surface.exists,
            "Expected the decision surface to dismiss after tapping '\(title)'.",
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

    /// Returns the first visible candidate from one explicit XCUI query list.
    func firstVisibleCandidate(
        from candidates: [XCUIElement],
        waitTimeout: TimeInterval = 0
    ) -> XCUIElement? {
        func visibleCandidate() -> XCUIElement? {
            for candidate in candidates where candidate.exists {
                if isElementHittable(candidate) || elementHasUsableFrame(candidate) {
                    return candidate
                }
            }
            return nil
        }

        if let candidate = visibleCandidate() {
            return candidate
        }

        guard waitTimeout > 0 else {
            return nil
        }

        var resolvedCandidate: XCUIElement?
        let predicate = NSPredicate(block: { _, _ in
            if let candidate = visibleCandidate() {
                resolvedCandidate = candidate
                return true
            }
            return false
        })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for visible candidate"
        let result = XCTWaiter().wait(for: [expectation], timeout: waitTimeout)
        if result == .completed {
            return resolvedCandidate ?? visibleCandidate()
        }
        return visibleCandidate()
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
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if let field = resolveVisibleSearchInput(in: app, waitTimeout: min(0.5, remaining)) {
                return field
            }
            revealSearchControls(in: app)
            if let field = resolveVisibleSearchInput(
                in: app,
                waitTimeout: min(0.5, max(0, deadline.timeIntervalSinceNow))
            ) {
                return field
            }
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
     Waits for the Settings screen to expose at least one stable production control.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before giving up.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: `true` when Settings is ready for interaction, otherwise `false`.
     * - Side effects:
     *   - attempts to dismiss the language restart confirmation between bounded readiness waits
     *   - waits on the Settings form root through XCTest's predicate waiter
     * - Failure modes: This helper does not fail directly.
     */
    func waitForSettingsReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        func settingsFormIsReady() -> Bool {
            if let settingsForm = resolvedElement("settingsForm", in: app),
               settingsForm.exists,
               !settingsForm.frame.isEmpty
            {
                return true
            }

            return resolvedElement("settingsForm", in: app) != nil
        }

        func dismissRestartAlertIfReady() {
            let alert = app.alerts.firstMatch
            let okButton = alert.buttons["OK"].firstMatch
            guard alert.exists,
                  okButton.exists,
                  elementHasUsableFrame(okButton)
            else {
                return
            }
            if okButton.isHittable {
                okButton.tap()
            } else {
                okButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        let waitInterval: TimeInterval = 0.5

        while true {
            dismissRestartAlertIfReady()

            let remaining = max(0, deadline.timeIntervalSinceNow)
            let didResolveSettings = waitForUITestCondition(
                "Wait for Settings ready",
                timeout: min(waitInterval, remaining)
            ) {
                settingsFormIsReady()
            }
            if didResolveSettings {
                return true
            }

            dismissRestartAlertIfReady()
            if settingsFormIsReady() {
                return true
            }

            guard Date() < deadline else {
                return false
            }
        }
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
     *   - evaluates the production `settingsForm` accessibility value through the shared semantic
     *     state waiter
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
        waitForResolvedSemanticState(
            named: "settingsForm",
            timeout: timeout,
            valueProvider: { self.semanticStateExportValue("settingsForm", in: app) },
            success: { $0.contains(expectedToken) },
            failureDescription: {
                "Expected Settings state to contain '\(expectedToken)' within \(timeout) seconds. Last state: '\($0)'."
            },
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
     *   - records an XCTest failure if the chooser search, pseudo-document row, or My Notes state
     *     never becomes visible
     */
    func openMyNotesFromReader(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapReaderAction("readerChooseDocumentAction", in: app, timeout: timeout, file: file, line: line)
        let searchField = requireElement(
            "modulePickerSearchField",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        replaceText(in: searchField, with: "My Note", placeholderHints: ["Search"])
        tapElementReliably(
            requireElement(
                "modulePickerPseudoRow::myNotes",
                in: app,
                timeout: timeout,
                file: file,
                line: line
            ),
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
