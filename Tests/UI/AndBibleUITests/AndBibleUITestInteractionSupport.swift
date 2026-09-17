import Foundation
import Darwin
import XCTest
import Vision
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
     *   - diagnosticName: Stable caller-owned name used in the wait description. Reading the live
     *     element's identifier or label solely for diagnostics would trigger two extra snapshots.
     *   - timeout: Maximum number of seconds to poll.
     * - Returns: `true` when XCTest reports the element as hittable before the timeout.
     * - Side effects:
     *   - observes the element through XCTest's predicate waiter while pending UI transitions settle
     * - Failure modes: This helper does not fail directly.
     */
    func waitForElementToBecomeHittable(
        _ element: XCUIElement,
        diagnosticName: String = "resolved UI element",
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition(
            "Wait for \(diagnosticName) to become hittable",
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

        XCTFail(
            "Expected the resolved UI element to become hittable before its single tap within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /// Taps once when the element becomes hittable; returns false without input otherwise.
    @discardableResult
    func tapElementIfPossible(
        _ element: XCUIElement,
        timeout: TimeInterval = 1
    ) -> Bool {
        if waitForElementToBecomeHittable(element, timeout: timeout) {
            element.tap()
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
     Taps one semantic action in an app-owned Android dialog and waits for the action to close.
     *
     * Native `XCUIElement.alerts` queries are deliberately excluded: application decisions use
     * shared Android dialog windows, while only operating-system handoffs may surface native iOS
     * alerts. Stable semantic IDs keep the test valid across translated button labels.
     *
     * - Parameters:
     *   - actionIdentifier: Full shared-dialog action identifier, including its semantic action ID.
     *   - dialogIdentifier: Stable identifier of the owning app dialog when SwiftUI exposes its
     *     noninteractive container separately from the parent activity.
     *   - dialogElement: Optional concrete-role query for that container. Supplying the observed
     *     role avoids a whole-tree fallback when the dialog's accessibility type is known.
     *   - expectedTitle: Optional English-locale label assertion that verifies visible copy without
     *     using it as the control locator.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the action and dismissal.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the real app-owned dialog action and blocks until that action disappears
     *   - also verifies container dismissal when the dialog container has its own accessible node
     * - Failure modes:
     *   - records an XCTest failure when the action is absent, visible copy is wrong, the action
     *     remains after activation, or an exposed dialog container remains after the action
     */
    func tapAppOwnedDialogAction(
        _ actionIdentifier: String,
        dialogIdentifier: String,
        dialogElement: XCUIElement? = nil,
        expectedTitle: String? = nil,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let dialog = dialogElement ?? resolvedElement(dialogIdentifier, in: app)
        let action = requireElement(actionIdentifier, in: app, timeout: timeout, file: file, line: line)
        if let expectedTitle {
            XCTAssertEqual(
                action.label,
                expectedTitle,
                "Expected app-owned dialog action '\(actionIdentifier)' to render translated copy '\(expectedTitle)'.",
                file: file,
                line: line
            )
        }

        tapElementReliably(action, timeout: timeout, file: file, line: line)
        waitForElementToDisappear(action, timeout: timeout, file: file, line: line)
        if let dialog {
            waitForElementToDisappear(dialog, timeout: timeout, file: file, line: line)
        }
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
     Passively waits for a visible Settings form without dismissing unrelated dialogs.

     - Parameters:
       - app: Running application under test.
       - timeout: Maximum time to observe Settings.
       - file: XCTest failure attribution source.
       - line: XCTest failure attribution line.
     - Returns: Whether the actual Settings form is visible in the application viewport.
     - Side effects: Samples accessibility through XCTest's predicate waiter.
     - Failure modes: Returns false when the form does not become visible. A caller that changes
       language or triggers another confirmation must explicitly exercise that dialog's action.
     */
    func waitForSettingsReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        waitForUITestCondition("Settings form becomes visible", timeout: timeout) {
            guard let form = self.resolvedElement("settingsForm", in: app),
                  self.elementHasUsableFrame(form) else { return false }
            return app.frame.intersects(form.frame)
        }
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
     *     native My Notes title; callers await their expected rendered content
     * - Failure modes:
     *   - records an XCTest failure if the chooser search, pseudo-document row, or My Notes title
     *     never appears; callers separately verify the actual rendered document
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
    }

    /**
     Tests whether Vision's ordered line observations contain the expected visible reader text.

     Vision preserves CSS line-end hyphenation as a trailing ASCII hyphen on one observation and
     the remainder of the word on the next. This matcher keeps observation boundaries as newlines
     and permits that exact `-\n` sequence between adjacent letters in the expected phrase.
     Ordinary expected whitespace can span a line boundary; authored hyphens remain required.

     - Parameters:
       - lines: Ordered best-candidate strings returned by the Vision text observations.
       - expectedText: The semantic visible phrase required by the journey.
     - Returns: `true` when the case-insensitive observed text contains the phrase, allowing only
       the evidenced line-boundary forms described above.
     - Side effects: none.
     - Failure modes: Returns `false` for empty expectations and when no projection contains the
       phrase. OCR cannot distinguish an authored hyphen from automatic hyphenation at the exact
       end of a line, so `-\n` is accepted as a discretionary break only where the expected phrase
       has adjacent letters.
     */
    func visibleReaderOCRLines(_ lines: [String], contain expectedText: String) -> Bool {
        let expected = expectedText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !expected.isEmpty else { return false }

        let observed = lines
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !observed.isEmpty else { return false }

        let expectedCharacters = Array(expected)
        var pattern = ""
        for index in expectedCharacters.indices {
            let character = expectedCharacters[index]
            if character.isWhitespace {
                pattern += #"\s+"#
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
                let nextIndex = expectedCharacters.index(after: index)
                if nextIndex < expectedCharacters.endIndex {
                    let next = expectedCharacters[nextIndex]
                    if character == "-" && !next.isWhitespace {
                        pattern += #"(?:\n)?"#
                    } else if character.isLetter && next.isLetter {
                        pattern += #"(?:-\n)?"#
                    }
                }
            }
        }
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return false }
        return expression.firstMatch(
            in: observed,
            range: NSRange(observed.startIndex..., in: observed)
        ) != nil
    }

    /**
     Awaits text drawn in the on-screen WebView without changing the interaction.

     Vision reads the actual composited WebView screenshot. WebKit can split scripture across
     accessibility nodes, and an editable note's action label can replace its text in that tree.
     Screenshot recognition observes both through the same boundary. These journeys use English
     fixtures; expected text is never supplied to Vision as a recognition hint. Native toolbar
     values and diagnostic snapshots cannot satisfy the check.

     - Parameters:
       - text: Expected text fragment in the rendered document.
       - app: Running single-pane application under test.
       - timeout: Maximum passive observation time.
       - file: XCTest failure attribution source.
       - line: XCTest failure attribution line.
     - Side effects: Captures the WebView and recognizes its pixels in the test runner; does not
       tap, scroll, or alter app state.
     - Failure modes: Records a failure if no matching visible reader text arrives before timeout.
     */
    func waitForVisibleReaderText(
        containing text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var observedText = ""
        var recognitionError: String?
        let expectedText = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let ready = waitForUITestCondition("Visible reader text: \(text)", timeout: timeout) {
            let webView = app.webViews.firstMatch
            guard webView.exists, self.elementHasUsableFrame(webView),
                  app.frame.contains(webView.frame),
                  let pixels = webView.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])
                let observedLines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                observedText = observedLines
                    .joined(separator: " ")
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                recognitionError = nil
                return self.visibleReaderOCRLines(observedLines, contain: expectedText)
            } catch {
                recognitionError = error.localizedDescription
                return false
            }
        }
        if !ready {
            XCTContext.runActivity(named: "Missing visible reader text: \(text)") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
                let recognition = XCTAttachment(string:
                    "Recognized visible text: \(observedText)\nError: \(recognitionError ?? "none")"
                )
                recognition.lifetime = .keepAlways
                activity.add(recognition)
            }
        }
        XCTAssertTrue(ready, "Expected visible reader text '\(text)'.", file: file, line: line)
    }

    /**
     Awaits usable Bookmarks navigation and content without tapping or consulting hidden exports.

     The Back and filter controls must fit inside the application viewport. The real scroll view
     must have visible area, and its first row or explicit empty state must be visible within it.
     A clipped filter alone cannot establish readiness for a zero-height or offscreen destination.
     Returns false on timeout; callers own failure reporting and any diagnostic attachments.
     This readiness check runs before the Bookmarks performance measurement interval. Its cached
     frame reads reduce XCTest observation work without changing a timed branch.
     */
    func waitForUsableBookmarkList(
        in app: XCUIApplication,
        requiresRows: Bool = false,
        timeout: TimeInterval = 30
    ) -> Bool {
        waitForUITestCondition("Usable Bookmarks destination", timeout: timeout) {
            let back = app.buttons["bookmarkListAppBarBackButton"]
            let filter = app.buttons["bookmarkListLabelFilterButton"]
            let scroll = app.scrollViews.firstMatch
            guard back.exists, filter.exists, scroll.exists else { return false }
            let appFrame = app.frame
            let backFrame = back.frame
            let filterFrame = filter.frame
            let scrollFrame = scroll.frame
            guard self.elementFrameIsUsable(backFrame),
                  self.elementFrameIsUsable(filterFrame),
                  self.elementFrameIsUsable(scrollFrame),
                  appFrame.contains(backFrame), appFrame.contains(filterFrame),
                  back.isHittable, filter.isHittable else { return false }
            let visibleScroll = scrollFrame.intersection(appFrame)
            guard !visibleScroll.isNull, visibleScroll.width >= 44,
                  visibleScroll.height >= 44 else { return false }
            let row = scroll.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "bookmarkListRowButton::")
            ).firstMatch
            if row.exists {
                let rowFrame = row.frame
                if self.elementFrameIsUsable(rowFrame), visibleScroll.intersects(rowFrame) {
                    return row.isHittable
                }
            }
            guard !requiresRows else { return false }
            let empty = app.staticTexts["bookmarkListEmptyText"]
            guard empty.exists else { return false }
            let emptyFrame = empty.frame
            return self.elementFrameIsUsable(emptyFrame) && visibleScroll.intersects(emptyFrame)
        }
    }

}
