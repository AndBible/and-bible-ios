import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func tapSettingsElement(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = requireSettingsNavigationControl(
            identifier,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        if waitForElementToBecomeHittable(element, timeout: min(2, timeout)) {
            element.tap()
            return
        }
        if let settingsForm = resolvedElement("settingsForm", in: app),
           isElementVisible(element, within: settingsForm)
        {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        tapElementReliably(element, timeout: timeout, file: file, line: line)
    }

    /**
     Opens the seeded `UI Test Seed` StudyPad handoff through the production bookmark-list controls.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - selects the real `UI Test Seed` filter chip
     *   - taps the production StudyPad handoff button shown for the selected label
     *   - dismisses the bookmark-list sheet if the handoff leaves it covering the reader
     * - Failure modes:
     *   - fails if the production label-filter or StudyPad handoff controls are unavailable
     */
    func openSeedStudyPadFromBookmarkList(in app: XCUIApplication) {
        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        tapElementReliably(requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10), timeout: 10)
        dismissBookmarkListIfVisible(in: app, timeout: 10)
    }

    /**
     Stable Search scope tokens mirrored from `SearchView` accessibility exports.
     */
    enum SearchScopeToken: String {
        case oldTestament
        case newTestament

        var fallbackLabel: String {
            switch self {
            case .oldTestament:
                "OT"
            case .newTestament:
                "NT"
            }
        }
    }

    /**
     Creates the deterministic `UI Test Fresh` label from the label-assignment sheet.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - opens the native create-label alert
     *   - fills the label name field and confirms creation
     * - Failure modes:
     *   - fails if the create-label alert cannot be presented or completed
     */
    func createFreshLabelFromAssignment(in app: XCUIApplication) {
        let labelName = "UI Test Fresh"
        presentLabelCreationPrompt(in: app, timeout: 10)
        let nameField = requireLabelManagerNewLabelField(in: app, timeout: 10)
        guard typePromptText(
            labelName,
            into: nameField,
            in: app,
            timeout: 15,
            accessibilityIdentifier: "labelManagerNewLabelNameField"
        ) else {
            return
        }
        tapLabelCreationPromptCreateButton(in: app, timeout: 10)
    }

    /**
     Types text into a prompt field and waits for XCTest to observe the committed value.

     Prompt-specific callers pass a field that was already resolved from a known modal/sheet.
     Those flows intentionally avoid app-wide focused-field probes and focus-predicate gates because
     hosted XCTest can hang while proving unrelated text fields do not exist or while rebuilding a
     native prompt snapshot.

     - Parameters:
       - text: Final text expected in the prompt-owned field.
       - element: Prompt text field resolved by a modal-specific helper.
       - app: Running application under test.
       - timeout: Maximum number of seconds to retry focus/type verification.
       - accessibilityIdentifier: Stable identifier for the field when resolving XCUI metadata is
         unsafe or unnecessarily expensive.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: `true` when the prompt field reports the expected value before submission.
     - Side effects:
       - taps the resolved prompt field, verifies or clears any existing prompt value, emits
         keyboard input, and clears/retries if CI drops the input without appending duplicate text
     - Failure modes:
       - records an XCTest failure when the field value never matches `text`
     */
    @discardableResult
    func typePromptText(
        _ text: String,
        into element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        accessibilityIdentifier: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let resolvedIdentifier = accessibilityIdentifier ?? element.identifier
        let placeholderHints = textEntryPlaceholderHints(for: resolvedIdentifier)
        let includeElementMetadata = accessibilityIdentifier == nil
        let deadline = Date().addingTimeInterval(timeout)

        let usesPromptScopedResolvedField = [
            "labelManagerNewLabelNameField",
            "workspaceNamePromptTextField",
        ].contains(resolvedIdentifier)

        func promptFocusedTextEntryCandidates() -> [XCUIElement] {
            usesPromptScopedResolvedField ? [] : focusedTextEntryCandidates(in: app)
        }

        func appCoordinate(for frame: CGRect, normalizedOffset: CGVector) -> XCUICoordinate? {
            let appFrame = app.frame
            guard elementFrameIsUsable(frame),
                  elementFrameIsUsable(appFrame),
                  appFrame.width > 0,
                  appFrame.height > 0
            else {
                return nil
            }

            let absoluteX = frame.minX + frame.width * normalizedOffset.dx
            let absoluteY = frame.minY + frame.height * normalizedOffset.dy
            return app.coordinate(
                withNormalizedOffset: CGVector(
                    dx: absoluteX / appFrame.width,
                    dy: absoluteY / appFrame.height
                )
            )
        }

        func resolvedPromptTextField() -> XCUIElement {
            if usesPromptScopedResolvedField {
                return element
            }

            if let prompt = resolvedModalPrompt(in: app, timeout: 0.2) {
                let promptCandidates: [XCUIElement]
                promptCandidates = modalTextFieldCandidates(
                    in: prompt,
                    identifiers: accessibilityIdentifier.map { [$0] } ?? [],
                    titles: placeholderHints
                )
                if let promptField = firstExistingElement(promptCandidates, timeout: 0.2) {
                    return promptField
                }
            }

            if let focusedField = firstExistingElement(promptFocusedTextEntryCandidates(), timeout: 0.2) {
                return focusedField
            }

            return element
        }

        func promptTextEntryCandidates(preferred preferredCandidates: [XCUIElement]) -> [XCUIElement] {
            if usesPromptScopedResolvedField {
                return preferredCandidates.isEmpty ? [element] : preferredCandidates
            }

            var candidates = preferredCandidates
            if preferredCandidates.isEmpty {
                candidates.append(resolvedPromptTextField())
            }
            candidates.append(element)
            candidates += promptFocusedTextEntryCandidates()
            return candidates
        }

        func promptOwnedTextEntryTapCoordinate() -> XCUICoordinate? {
            switch resolvedIdentifier {
            case "labelManagerNewLabelNameField":
                guard let prompt = resolvedLabelCreationPrompt(in: app),
                      elementFrameIsUsable(prompt.frame) else {
                    return nil
                }
                return appCoordinate(
                    for: prompt.frame,
                    normalizedOffset: CGVector(dx: 0.5, dy: 0.52)
                )
            case "workspaceNamePromptTextField":
                // The workspace prompt resolver already found the text field. Re-sampling the
                // custom SwiftUI prompt root for its frame can wedge hosted XCTest snapshots, so
                // let `focusResolvedPromptTextEntryElement` use the resolved field directly.
                return nil
            default:
                return nil
            }
        }

        func observedPromptTextValue(preferred preferredCandidates: [XCUIElement] = []) -> String {
            let candidates = promptTextEntryCandidates(preferred: preferredCandidates)
            var fallbackValue = ""
            for candidate in candidates where usesPromptScopedResolvedField || candidate.exists {
                let candidateValue = currentTextEntryValue(
                    in: candidate,
                    placeholderHints: placeholderHints,
                    includeElementMetadata: includeElementMetadata
                )
                if candidateValue == text {
                    return candidateValue
                }
                if fallbackValue.isEmpty, !candidateValue.isEmpty {
                    fallbackValue = candidateValue
                }
            }
            return fallbackValue
        }

        func waitForObservedPromptTextValue(
            preferred preferredCandidates: [XCUIElement] = [],
            timeout: TimeInterval
        ) -> Bool {
            let valueDeadline = Date().addingTimeInterval(timeout)
            repeat {
                if observedPromptTextValue(preferred: preferredCandidates) == text {
                    return true
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < valueDeadline
            return observedPromptTextValue(preferred: preferredCandidates) == text
        }

        func waitForObservedPromptTextValueToClear(
            preferred preferredCandidates: [XCUIElement],
            timeout: TimeInterval
        ) -> Bool {
            let clearDeadline = Date().addingTimeInterval(timeout)
            repeat {
                if observedPromptTextValue(preferred: preferredCandidates).isEmpty {
                    return true
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            } while Date() < clearDeadline
            return observedPromptTextValue(preferred: preferredCandidates).isEmpty
        }

        func clearObservedPromptTextValue(
            preferred preferredCandidates: [XCUIElement],
            forceKeyboardDelete: Bool = false
        ) -> Bool {
            func focusCandidateForKeyboardDelete(_ candidate: XCUIElement) {
                if usesPromptScopedResolvedField {
                    focusResolvedPromptTextEntryElement(
                        candidate,
                        in: app,
                        preferTrailingEdge: true,
                        promptTapCoordinate: promptOwnedTextEntryTapCoordinate,
                        timeout: 1,
                        file: file,
                        line: line
                    )
                } else {
                    focusTextEntryElement(candidate, preferTrailingEdge: true, timeout: 1)
                }
            }

            let candidates = promptTextEntryCandidates(preferred: preferredCandidates)
            for candidate in candidates where usesPromptScopedResolvedField || candidate.exists {
                let scopedPreferredCandidates = preferredCandidates + [candidate]
                if usesPromptScopedResolvedField,
                   observedPromptTextValue(preferred: scopedPreferredCandidates).isEmpty {
                    return true
                }

                if forceKeyboardDelete {
                    focusCandidateForKeyboardDelete(candidate)
                    if usesPromptScopedResolvedField {
                        app.typeText(
                            String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(text.count * 2, 32))
                        )
                        if waitForObservedPromptTextValueToClear(
                            preferred: scopedPreferredCandidates,
                            timeout: 0.5
                        ) {
                            return true
                        }
                    } else if waitForElementKeyboardFocus(candidate, timeout: 0.3) {
                        app.typeText(
                            String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(text.count * 2, 32))
                        )
                        if waitForObservedPromptTextValueToClear(
                            preferred: scopedPreferredCandidates,
                            timeout: 0.5
                        ) {
                            return true
                        }
                    }
                }

                if usesPromptScopedResolvedField {
                    continue
                }

                if clearTextEntryElement(
                    candidate,
                    app: app,
                    placeholderHints: placeholderHints,
                    includeElementMetadata: includeElementMetadata
                ) && waitForObservedPromptTextValueToClear(
                    preferred: scopedPreferredCandidates,
                    timeout: 0.5
                ) {
                    return true
                }
            }

            return observedPromptTextValue(preferred: preferredCandidates).isEmpty
        }

        repeat {
            let promptTextField = resolvedPromptTextField()
            let preferredPromptCandidates = [promptTextField]
            focusResolvedPromptTextEntryElement(
                promptTextField,
                in: app,
                promptTapCoordinate: promptOwnedTextEntryTapCoordinate,
                timeout: min(5, max(1, deadline.timeIntervalSinceNow)),
                file: file,
                line: line
            )
            let existingValue = observedPromptTextValue(preferred: preferredPromptCandidates)
            if existingValue == text {
                return true
            }
            guard clearObservedPromptTextValue(preferred: preferredPromptCandidates, forceKeyboardDelete: true) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            if usesPromptScopedResolvedField {
                app.typeText(text)
            } else {
                promptTextField.typeText(text)
            }
            if waitForObservedPromptTextValue(
                preferred: preferredPromptCandidates,
                timeout: min(5, max(0.5, deadline.timeIntervalSinceNow))
            ) {
                return true
            }

            if !usesPromptScopedResolvedField,
               waitForElementKeyboardFocus(promptTextField, timeout: 0.5) {
                let currentValue = observedPromptTextValue(preferred: preferredPromptCandidates)
                if currentValue == text {
                    return true
                }
                if !currentValue.isEmpty {
                    _ = clearObservedPromptTextValue(preferred: preferredPromptCandidates, forceKeyboardDelete: true)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    continue
                }

                guard clearObservedPromptTextValue(
                    preferred: preferredPromptCandidates,
                    forceKeyboardDelete: true
                ) else {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    continue
                }

                app.typeText(text)
                if waitForObservedPromptTextValue(
                    preferred: preferredPromptCandidates,
                    timeout: min(3, max(0.5, deadline.timeIntervalSinceNow))
                ) {
                    return true
                }
            }

            _ = clearObservedPromptTextValue(preferred: preferredPromptCandidates, forceKeyboardDelete: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertEqual(
            observedPromptTextValue(),
            text,
            "Expected prompt text input '\(resolvedIdentifier)' to contain '\(text)' before submitting.",
            file: file,
            line: line
        )
        return false
    }

    /**
     Dismisses Label Assignment back to the bookmark list and waits for the parent state to settle.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the sheet dismissal to complete.
     * - Side effects:
     *   - taps the production done button on Label Assignment, retrying when a hosted simulator
     *     accepts the event without running the SwiftUI action
     *   - polls the bookmark-list state export until the parent reports that Label Assignment is
     *     no longer presented
     * - Failure modes:
     *   - fails if the parent bookmark-list state never reports Label Assignment dismissed within
     *     the timeout
     */
    func dismissLabelAssignmentToBookmarkList(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapElementReliably(
            requireElement("labelAssignmentDoneButton", in: app, timeout: timeout),
            timeout: timeout
        )

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let bookmarkListState = resolvedBookmarkListStateValue(in: app),
               bookmarkListState.contains("labelAssignment=false") {
                return
            }

            if let doneButton = resolvedElement("labelAssignmentDoneButton", in: app) {
                _ = tapElementIfPossible(doneButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow)))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        let finalState = resolvedBookmarkListStateValue(in: app) ?? "nil"
        XCTAssertTrue(
            finalState.contains("labelAssignment=false"),
            "Expected Label Assignment to dismiss within \(timeout) seconds. Final bookmark-list state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /**
     Opens the create-label prompt from Label Assignment and waits for its field or action to
     surface before returning.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep retrying the production create-label control.
     * - Side effects:
     *   - taps the real create-label button and polls the live accessibility hierarchy for the
     *     prompt field/button until one appears
     * - Failure modes:
     *   - records an XCTest failure if the prompt never becomes reachable within the timeout
     */
    func presentLabelCreationPrompt(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let trigger = requireElement("labelAssignmentCreateNewLabelButton", in: app, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            tapElementReliably(trigger, timeout: 5)
            if resolveLabelCreationPromptTextField(in: app) != nil
                || resolveLabelCreationPromptCreateButton(in: app) != nil
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected the Label Manager create prompt to appear within \(timeout) seconds.")
    }

    /**
     Submits the native create-label alert without repeatedly snapshotting its action button.

     Hosted simulators can wedge XCTest while evaluating the alert's `Create` button after text
     entry. Once the prompt and committed text are already observed, tapping the alert's trailing
     action area exercises the same visible control while avoiding that unstable query path.

     - Parameters:
       - app: Running application under test.
       - timeout: Maximum time to wait for the prompt surface to expose a usable frame.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Side effects:
       - taps the native alert action area that confirms label creation
     - Failure modes:
       - records an XCTest failure if the prompt never exposes a tappable frame
     */
    func tapLabelCreationPromptCreateButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let prompt = resolvedLabelCreationPrompt(in: app),
               elementFrameIsUsable(prompt.frame) {
                prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.86)).tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected the create-label prompt to expose a usable frame within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Returns the visible native prompt container used by the create-label flow.

     - Parameter app: Running application under test.
     - Returns: The title-matched alert/sheet used by the create-label prompt, or the current
       native prompt surface when SwiftUI has exposed the text field but not the alert title.
     - Side effects: none.
     - Failure modes: returns `nil` when XCTest cannot observe a presented prompt.
     */
    func resolvedLabelCreationPrompt(in app: XCUIApplication) -> XCUIElement? {
        firstExistingElement(
            [
                app.alerts["New Label"].firstMatch,
                app.sheets["New Label"].firstMatch,
                app.alerts.firstMatch,
                app.sheets.firstMatch,
            ],
            timeout: 0.2
        )
    }

    /**
     Returns app-scoped create-label text field candidates in stable lookup order.

     Label Manager creation prompts are SwiftUI alerts. Secure-field candidates are intentionally
     omitted because the prompt never uses secure entry, and hosted runners can stall while proving
     a non-existent secure field is absent.

     - Parameter app: Running application under test.
     - Returns: Text-field candidates ordered from localized placeholder to explicit identifier.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func appScopedLabelCreationPromptTextFieldCandidates(in app: XCUIApplication) -> [XCUIElement] {
        [
            app.textFields["Label name"].firstMatch,
            app.textFields["labelManagerNewLabelNameField"].firstMatch,
        ]
    }

    /**
     Returns app-scoped create-label action candidates in stable lookup order.

     - Parameter app: Running application under test.
     - Returns: Button candidates ordered from explicit identifier to localized title.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func appScopedLabelCreationPromptCreateButtonCandidates(in app: XCUIApplication) -> [XCUIElement] {
        [
            app.buttons["labelManagerCreateButton"].firstMatch,
            app.buttons["Create"].firstMatch,
        ]
    }

    /**
     Returns create-label text field candidates using stable alert names.

     Hosted simulators can wedge XCTest while resolving absent secure-field or ordinal text-entry
     candidates inside a SwiftUI alert, so prompt polling uses only the visible title and explicit
     production identifier.
     */
    func labelCreationPromptTextFieldCandidates(in prompt: XCUIElement) -> [XCUIElement] {
        [
            prompt.textFields["Label name"].firstMatch,
            prompt.textFields["labelManagerNewLabelNameField"].firstMatch,
        ]
    }

    /**
     Returns create-label button candidates with the accessibility identifier before title
     matching.
     */
    func labelCreationPromptCreateButtonCandidates(in prompt: XCUIElement) -> [XCUIElement] {
        [
            prompt.buttons["labelManagerCreateButton"].firstMatch,
            prompt.buttons["Create"].firstMatch,
        ]
    }

    /// Resolves the create-label prompt text field by scoping queries to the visible prompt.
    func resolveLabelCreationPromptTextField(in app: XCUIApplication) -> XCUIElement? {
        if let prompt = resolvedLabelCreationPrompt(in: app) {
            if let field = firstExistingElement(
                labelCreationPromptTextFieldCandidates(in: prompt),
                timeout: 0.2
            ) {
                return field
            }
        }
        return firstExistingElement(
            appScopedLabelCreationPromptTextFieldCandidates(in: app),
            timeout: 0
        )
    }

    /// Resolves the create-label prompt action button by scoping queries to the visible prompt.
    func resolveLabelCreationPromptCreateButton(in app: XCUIApplication) -> XCUIElement? {
        if let prompt = resolvedLabelCreationPrompt(in: app) {
            if let button = firstExistingElement(
                labelCreationPromptCreateButtonCandidates(in: prompt),
                timeout: 0.2
            ) {
                return button
            }
        }
        return firstExistingElement(
            appScopedLabelCreationPromptCreateButtonCandidates(in: app),
            timeout: 0
        )
    }

    /// Resolves the Search root element that owns the canonical UI-test state value.
    func resolvedSearchScreenElement(in app: XCUIApplication) -> XCUIElement? {
        resolvedElement("searchScreen", in: app)
    }

    /// Resolves the canonical Search state element without walking result-row static text nodes.
    func resolvedSearchStateElement(in app: XCUIApplication) -> XCUIElement? {
        resolvedStateExportElement("searchStateExport", in: app)
    }

    /// Reads Search state from the first state-bearing candidate that exposes a settled value.
    func searchStateCandidateValues(in app: XCUIApplication) -> [String] {
        if let value = semanticStateExportValue("searchStateExport", in: app),
           value.contains("state=") {
            return [value]
        }
        return []
    }

    /// Reads the current exported Search state from the state-bearing root element.
    func resolvedSearchStateValue(in app: XCUIApplication) -> String? {
        searchStateCandidateValues(in: app).first
    }

    /// Reads the current exported Bookmark List state without walking the full list hierarchy.
    func resolvedBookmarkListStateValue(in app: XCUIApplication) -> String? {
        if let value = semanticStateExportValue("bookmarkListStateExport", in: app) {
            return value
        }
        if let screen = resolvedElement("bookmarkListScreen", in: app),
           let value = screen.value as? String {
            return value
        }
        return nil
    }

    /// Reads the current exported Reading Plans list state without walking the full list hierarchy.
    func resolvedReadingPlanListStateValue(in app: XCUIApplication) -> String? {
        if let value = semanticStateExportValue("readingPlanListStateExport", in: app) {
            return value
        }
        if let screen = resolvedElement("readingPlanListScreen", in: app),
           let value = screen.value as? String {
            return value
        }
        return nil
    }

    /// Reads the current exported Available Plans state without walking the full picker hierarchy.
    func resolvedAvailablePlansStateValue(in app: XCUIApplication) -> String? {
        if let value = semanticStateExportValue("availablePlansStateExport", in: app) {
            return value
        }
        if let screen = resolvedElement("availablePlansScreen", in: app),
           let value = screen.value as? String {
            return value
        }
        return nil
    }

    /// Reads the current exported Label Manager state without broad prompt/list queries.
    func resolvedLabelManagerStateValue(in app: XCUIApplication) -> String? {
        if let value = semanticStateExportValue("labelManagerStateExport", in: app) {
            return value
        }
        if let screen = resolvedElement("labelManagerScreen", in: app),
           let value = screen.value as? String {
            return value
        }
        return nil
    }

    /**
     Waits for a lightweight exported semantic state value instead of re-querying full XCUI surfaces.
     *
     * - Parameters:
     *   - name: Logical identifier used in failure messages.
     *   - timeout: Maximum time to keep polling before failing.
     *   - valueProvider: Closure returning the currently exported semantic state.
     *   - success: Predicate that should become true before the timeout.
     *   - missingCountsAsSuccess: When true, treats a missing export as success.
     *   - failureDescription: Closure that formats the final failure message from the last value.
     * - Side effects:
     *   - evaluates a dedicated state export through `XCTNSPredicateExpectation` and `XCTWaiter`
     *     until the predicate succeeds
     * - Failure modes:
     *   - records an XCTest failure with elapsed wait time, final observed state, and last observed
     *     state if the predicate never succeeds before the timeout expires
     */
    func waitForResolvedSemanticState(
        named name: String,
        timeout: TimeInterval,
        valueProvider: @escaping () -> String?,
        success: @escaping (String) -> Bool,
        missingCountsAsSuccess: Bool = false,
        failureDescription: (String) -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let startedAt = Date()
        var lastObservedValue: String?
        let predicate = NSPredicate(block: { _, _ in
            if let currentValue = valueProvider() {
                lastObservedValue = currentValue
                if success(currentValue) {
                    return true
                }
            } else if missingCountsAsSuccess {
                return true
            }
            return false
        })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for \(name) semantic state"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result == .completed {
            return
        }

        let lastObservedBeforeFinalRead = lastObservedValue
        if let finalValue = valueProvider() {
            if success(finalValue) {
                return
            }
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            let lastObservedState = lastObservedBeforeFinalRead ?? "<none>"
            XCTFail(
                "\(failureDescription(finalValue)) Semantic wait '\(name)' ended with \(result) "
                    + "after elapsed=\(elapsed)s; final observed state='\(finalValue)'; "
                    + "last observed state='\(lastObservedState)'.",
                file: file,
                line: line
            )
        } else if missingCountsAsSuccess {
            return
        } else {
            let missingValue = "<missing \(name)>"
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(startedAt))
            let lastObservedState = lastObservedBeforeFinalRead ?? "<none>"
            XCTFail(
                "\(failureDescription(missingValue)) Semantic wait '\(name)' ended with \(result) "
                    + "after elapsed=\(elapsed)s; final observed state='\(missingValue)'; "
                    + "last observed state='\(lastObservedState)'.",
                file: file,
                line: line
            )
        }
    }

    /**
     Switches the bookmark list into Bible-order sorting through the production sort menu.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - opens the production sort menu and selects the Bible-order option
     * - Failure modes:
     *   - fails if the sort menu or Bible-order option is unavailable
     */
    func sortBookmarkListByBibleOrder(in app: XCUIApplication) {
        requireElement("bookmarkListSortMenu", in: app, timeout: 10).tap()
        requireElement("bookmarkListSortOption::bibleOrder", in: app, timeout: 10).tap()
    }

    /**
     Taps one inline Label Assignment control until the row reports the expected semantic value.
     *
     * - Parameters:
     *   - controlPrefix: Accessibility identifier prefix for the inline control to tap.
     *   - labelSegment: Identifier-safe label segment shared by the row and inline controls.
     *   - expectedRowValue: Full row accessibility value expected after the mutation.
     *   - expectedControlValue: Control accessibility value expected after the mutation.
     *   - app: Running application under test.
     *   - timeout: Maximum time allowed for the row state to settle.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - re-resolves the row and inline control while polling
     *   - retries the tap only while the control itself still reports the pre-mutation state
     * - Failure modes:
     *   - fails if the row never reaches `expectedRowValue` before timeout
     */
    func tapLabelAssignmentControlUntilRowValue(
        _ controlPrefix: String,
        labelSegment: String,
        expectedRowValue: String,
        expectedControlValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rowIdentifier = "labelAssignmentRow::\(labelSegment)"
        let controlIdentifier = "\(controlPrefix)::\(labelSegment)"
        let deadline = Date().addingTimeInterval(timeout)
        var didTap = false
        var lastTapTime = Date.distantPast
        var lastRowValue = "nil"
        var lastControlValue = "nil"

        repeat {
            if let row = resolvedElement(rowIdentifier, in: app) {
                lastRowValue = row.value.map { "\($0)" } ?? "nil"
                if lastRowValue == expectedRowValue {
                    return
                }
            } else {
                lastRowValue = "missing"
            }

            if let control = resolvedElement(controlIdentifier, in: app) {
                lastControlValue = control.value.map { "\($0)" } ?? "nil"
                if lastControlValue != expectedControlValue,
                   !didTap || Date().timeIntervalSince(lastTapTime) >= 1.0 {
                    let remaining = max(0.1, deadline.timeIntervalSinceNow)
                    if tapElementIfPossible(control, timeout: min(1, remaining)) {
                        didTap = true
                        lastTapTime = Date()
                    }
                }
            } else {
                lastControlValue = "missing"
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected label assignment row '\(rowIdentifier)' to reach value '\(expectedRowValue)' within \(timeout) seconds; last row value was '\(lastRowValue)' and last control value for '\(controlIdentifier)' was '\(lastControlValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Toggles the seeded label row inside Label Assignment and verifies the combined state change.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - taps the seeded label's favourite and assignment controls
     *   - waits for the row accessibility value to update to the combined assigned/favourite state
     * - Failure modes:
     *   - fails if the seed row or either inline control is missing
     *   - fails if the row accessibility value never reaches `assigned,favourite`
     */
    func assertSeedLabelAssignmentCanToggle(in app: XCUIApplication) {
        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        let initialState = seedRow.value as? String
        XCTAssertTrue(
            initialState == "assigned,notFavourite" || initialState == "unassigned,notFavourite",
            "Expected the seeded label row to start in a known non-favourite state, got '\(initialState ?? "nil")'."
        )

        _ = requireElement(
            "labelAssignmentFavouriteButton::UI_Test_Seed",
            in: app,
            timeout: 10
        )
        _ = requireElement(
            "labelAssignmentToggleButton::UI_Test_Seed",
            in: app,
            timeout: 10
        )

        let favouritedState = initialState == "assigned,notFavourite"
            ? "assigned,favourite"
            : "unassigned,favourite"
        tapLabelAssignmentControlUntilRowValue(
            "labelAssignmentFavouriteButton",
            labelSegment: "UI_Test_Seed",
            expectedRowValue: favouritedState,
            expectedControlValue: "favourite",
            in: app,
            timeout: 10
        )

        if initialState == "assigned,notFavourite" {
            tapLabelAssignmentControlUntilRowValue(
                "labelAssignmentToggleButton",
                labelSegment: "UI_Test_Seed",
                expectedRowValue: "unassigned,favourite",
                expectedControlValue: "unassigned",
                in: app,
                timeout: 10
            )
        }

        tapLabelAssignmentControlUntilRowValue(
            "labelAssignmentToggleButton",
            labelSegment: "UI_Test_Seed",
            expectedRowValue: "assigned,favourite",
            expectedControlValue: "assigned",
            in: app,
            timeout: 10
        )
    }

    /**
     Resolves one workspace row by its accessibility label.
     *
     * - Parameters:
     *   - name: User-visible workspace name expected on the row.
     *   - app: Running application under test.
     * - Returns: The first matching workspace-selector row button for the requested workspace.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a workspace-selector row whose label matches
     *     `name`
     * - Failure modes:
     *   - returns an unresolved query when no matching row currently exists
     */
    func workspaceRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", name)
        return app.buttons
            .matching(identifier: "workspaceSelectorRowButton")
            .matching(predicate)
            .firstMatch
    }

    /**
     Waits for a workspace row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - name: User-visible workspace name expected on the row.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved workspace-row UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested row exists or the timeout
     *     expires
     * - Failure modes:
     *   - records an XCTest failure if the row never appears within the requested timeout
     */
    func requireWorkspaceRow(
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = workspaceRow(named: name, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected workspace row '\(name)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the active workspace row to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first workspace row whose accessibility value is `activeWorkspace`.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the active workspace row exists or the
     *     timeout expires
     * - Failure modes:
     *   - records an XCTest failure if no active workspace row becomes visible within the timeout
     */
    func requireActiveWorkspaceRow(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "value == %@", "activeWorkspace")
        let element = app.buttons
            .matching(identifier: "workspaceSelectorRowButton")
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected an active workspace row within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one workspace inline action by button identifier and workspace label.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the workspace selector inline action.
     *   - workspaceName: User-visible workspace name attached to the button's accessibility label.
     *   - app: Running application under test.
     * - Returns: The first matching inline action button.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a button whose identifier and label match
     *     the requested workspace action
     * - Failure modes:
     *   - returns an unresolved query when no matching inline action button currently exists
     */
    func workspaceInlineAction(
        identifier: String,
        workspaceName: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let labelPredicate = NSPredicate(format: "label == %@", workspaceName)
        return app.buttons
            .matching(identifier: identifier)
            .matching(labelPredicate)
            .firstMatch
    }

    /**
     Waits for a workspace inline action and records a precise failure if it does not appear.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the workspace selector inline action.
     *   - workspaceName: User-visible workspace name attached to the button's accessibility label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved inline workspace-action UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested inline action becomes visible
     * - Failure modes:
     *   - records an XCTest failure if the action never appears within the requested timeout
     */
    func requireWorkspaceInlineAction(
        identifier: String,
        workspaceName: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = workspaceInlineAction(
            identifier: identifier,
            workspaceName: workspaceName,
            in: app
        )
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected workspace action '\(identifier)' for '\(workspaceName)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one label row by its accessibility label.
     *
     * - Parameters:
     *   - name: User-visible label name expected on the row.
     *   - app: Running application under test.
     * - Returns: The first matching Label Manager row button for the requested label name.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a label-manager row whose label matches
     *     `name`
     * - Failure modes:
     *   - returns an unresolved query when no matching row currently exists
     */
    func labelRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "labelManagerRowButton-\(name)"
        if let labelManagerScreen = resolvedElement("labelManagerScreen", in: app) {
            let scopedButton = labelManagerScreen.buttons[identifier].firstMatch
            if scopedButton.exists {
                return scopedButton
            }
            let scopedLink = labelManagerScreen.links[identifier].firstMatch
            if scopedLink.exists {
                return scopedLink
            }
        }

        let globalButton = app.buttons[identifier].firstMatch
        if globalButton.exists {
            return globalButton
        }
        let globalLink = app.links[identifier].firstMatch
        if globalLink.exists {
            return globalLink
        }
        return globalButton
    }

    /**
     Waits for a label row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - name: User-visible label name expected on the row.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved label-row UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested row exists or the timeout
     *     expires
     * - Failure modes:
     *   - records an XCTest failure if the row never appears within the requested timeout
     */
    func requireLabelRow(
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = labelRow(named: name, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected label row '\(name)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one label inline action by button identifier and label name.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the label-manager inline action.
     *   - labelName: User-visible label name attached to the button's accessibility label.
     *   - app: Running application under test.
     * - Returns: The first matching inline action button.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a button whose identifier and label match
     *     the requested label action
     * - Failure modes:
     *   - returns an unresolved query when no matching inline action button currently exists
     */
    func labelInlineAction(
        identifier: String,
        labelName: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons["\(identifier)-\(labelName)"]
    }

    /**
     Waits for a label inline action and records a precise failure if it does not appear.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the label-manager inline action.
     *   - labelName: User-visible label name attached to the button's accessibility label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved inline label-action UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested inline action becomes visible
     * - Failure modes:
     *   - records an XCTest failure if the action never appears within the requested timeout
     */
    func requireLabelInlineAction(
        identifier: String,
        labelName: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = labelInlineAction(identifier: identifier, labelName: labelName, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected label action '\(identifier)' for '\(labelName)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Replaces the entire contents of one text field with a new string.
     *
     * - Parameters:
     *   - element: Text field to overwrite.
     *   - text: Replacement text that should become the field's entire value.
     * - Side effects:
     *   - focuses the field, emits delete keystrokes for the current value, and types the
     *     replacement text through XCTest's software keyboard bridge
     * - Failure modes:
     *   - if the field reports a non-string value, the helper falls back to appending `text`
     *     instead of first deleting existing content
     */
    func replaceText(
        in element: XCUIElement,
        with text: String,
        placeholderHints: [String] = []
    ) {
        let existingText = currentTextEntryValue(in: element, placeholderHints: placeholderHints)
        if existingText == text {
            return
        }

        let app = trackedApp ?? XCUIApplication()
        if !clearTextEntryElement(element, app: app, placeholderHints: placeholderHints) {
            XCTFail(
                "Expected text input '\(element.identifier)' to clear before typing replacement text. "
                    + "Label: '\(element.label)'. Value: '\(String(describing: element.value))'."
            )
            return
        }

        if !text.isEmpty {
            app.typeText(text)
        }
    }

    /**
     Replaces a text field when the current value is already known by the test.

     This avoids sampling `element.value`, which can force XCTest to rebuild large SwiftUI
     snapshots for modal text fields in CI. Callers verify the result through the owning screen's
     semantic state instead of the transient field value.

     * - Parameters:
     *   - element: Focusable text-entry element whose current contents should be replaced.
     *   - existingCharacterCount: Number of characters to delete after focusing the trailing edge.
     *   - text: Replacement text typed through the XCTest keyboard bridge.
     *   - app: Running app used for keyboard input.
     * - Side effects:
     *   - focuses the field, sends delete keystrokes for the known current contents, and types the
     *     replacement text
     * - Failure modes:
     *   - focus failures are reported by `focusTextEntryElement`
     */
    func replaceKnownText(
        in element: XCUIElement,
        existingCharacterCount: Int,
        with text: String,
        app: XCUIApplication
    ) {
        focusTextEntryElement(element, preferTrailingEdge: true, timeout: 10)
        if existingCharacterCount > 0 {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingCharacterCount))
        }
        if !text.isEmpty {
            app.typeText(text)
        }
    }

    /**
     Resolves the current user-entered text for one text-entry control.
     *
     * - Parameter element: Focused text field or search field.
     * - Returns: The editable field contents, excluding placeholder text inferred from stable
     *   identifiers, optional metadata, and static hints when the control is currently empty.
     * - Parameter includeElementMetadata: Whether to sample `identifier` and `label` from XCUI.
     *   Prompt callers can disable this when stable placeholder hints are already known.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func currentTextEntryValue(
        in element: XCUIElement,
        placeholderHints: [String] = [],
        includeElementMetadata: Bool = true
    ) -> String {
        guard let rawValue = element.value as? String else {
            return ""
        }

        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            return ""
        }

        var placeholderCandidates = placeholderHints
        if includeElementMetadata {
            let identifier = element.identifier
            placeholderCandidates += [
                identifier,
                element.label,
            ]
            placeholderCandidates += textEntryPlaceholderHints(for: identifier)
        }

        let normalizedPlaceholderCandidates = Set(
            placeholderCandidates
                .map { normalizedTextEntrySemanticValue($0) }
                .filter { !$0.isEmpty }
        )
        let semanticCandidates = textEntrySemanticValueCandidates(from: rawValue)
        if semanticCandidates.contains(where: { normalizedPlaceholderCandidates.contains($0) }) {
            return ""
        }

        return rawValue
    }

    /// Normalizes one text-entry value for placeholder comparisons without losing the original text.
    func normalizedTextEntrySemanticValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /**
     Builds semantic comparison candidates from one XCUI text-entry value.
     *
     * XCUI occasionally decorates empty SwiftUI fields with control metadata such as
     * "Label name, Text Field" or "Search bookmarks, Search Field". The helper keeps the
     * original text intact for assertions but derives stable placeholder-comparison variants.
     */
    func textEntrySemanticValueCandidates(from rawValue: String) -> Set<String> {
        let normalized = normalizedTextEntrySemanticValue(rawValue)
        guard !normalized.isEmpty else {
            return []
        }

        var candidates: Set<String> = [normalized]

        let commaPrefix = normalized
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let commaPrefix, !commaPrefix.isEmpty {
            candidates.insert(commaPrefix)
        }

        let knownSuffixes = [
            " text field",
            " search field",
            " secure text field",
            " is editing",
        ]
        for suffix in knownSuffixes where normalized.hasSuffix(suffix) {
            let stripped = normalized
                .dropLast(suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                candidates.insert(stripped)
            }
        }

        if normalized.hasPrefix("optional("), normalized.hasSuffix(")") {
            let startIndex = normalized.index(normalized.startIndex, offsetBy: "optional(".count)
            let unwrapped = normalized[startIndex..<normalized.index(before: normalized.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unwrapped.isEmpty {
                candidates.insert(unwrapped)
            }
        }

        return candidates
    }

    /// Returns static placeholder hints for text-entry controls without querying XCUI metadata.
    func textEntryPlaceholderHints(for identifier: String) -> [String] {
        switch identifier {
        case "searchQueryField":
            return ["Search"]
        case "workspaceNamePromptTextField":
            return ["Name", "name"]
        case "labelManagerNewLabelNameField", "labelEditNameField":
            return ["Label name"]
        case "syncNextCloudServerURLField":
            return ["Server URI"]
        default:
            return []
        }
    }

    /**
     Attempts to select the entire current field contents through the iOS edit menu.
     *
     * - Parameters:
     *   - element: Focused text-entry element whose contents should be selected.
     *   - app: Running application hosting the system edit menu.
     * - Returns: `true` when "Select All" became available and was tapped.
     * - Side effects:
     *   - double-taps the field and, when needed, long-presses it to surface edit actions
     * - Failure modes: This helper does not fail directly.
     */
    func selectAllTextIfAvailable(
        in element: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let selectAllMenuItem = app.menuItems["Select All"].firstMatch

        func tapSelectAllIfPresent(timeout: TimeInterval) -> Bool {
            if selectAllMenuItem.waitForExistence(timeout: timeout) {
                selectAllMenuItem.tap()
                return true
            }
            return false
        }

        element.press(forDuration: 1.0)
        if tapSelectAllIfPresent(timeout: 1) {
            return true
        }

        element.tap()
        return tapSelectAllIfPresent(timeout: 0.5)
    }

    /**
     Pastes text through the system edit menu into a focused text-entry control.
     */
    func pasteTextIntoFocusedElement(
        _ text: String,
        in app: XCUIApplication,
        sourceElement element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
#if canImport(UIKit)
        let previousPasteboardText = UIPasteboard.general.string
        UIPasteboard.general.string = text
        defer {
            UIPasteboard.general.string = previousPasteboardText
        }

        let pasteMenuItem = app.menuItems["Paste"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if pasteMenuItem.waitForExistence(timeout: 0.5) {
                pasteMenuItem.tap()
                return
            }

            if element.exists && !element.frame.isEmpty {
                element.press(forDuration: 0.8)
                if pasteMenuItem.waitForExistence(timeout: 0.5) {
                    pasteMenuItem.tap()
                    return
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected Paste edit-menu action for text entry '\(element.identifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
#else
        XCTFail("Paste-driven text entry requires UIKit pasteboard access.", file: file, line: line)
#endif
    }

    /**
     Focuses one text-entry control through XCTest's native tap path without coordinate fallback.
     *
     * - Parameters:
     *   - element: Text field or search field that should receive keyboard focus.
     *   - requireExistencePreflight: Whether to run an explicit existence wait before tapping.
     *   - timeout: Maximum number of seconds to wait for the control to expose a stable frame.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the text input to exist, then taps it directly so the software keyboard can
     *     attach without the slower coordinate-based path
     * - Failure modes:
     *   - records an XCTest failure if the text input never exists or never exposes a non-empty
     *     frame before timeout
     */
    func focusTextEntryElement(
        _ element: XCUIElement,
        preferTrailingEdge: Bool = false,
        requireExistencePreflight: Bool = true,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if requireExistencePreflight {
            XCTAssertTrue(
                element.waitForExistence(timeout: timeout),
                "Expected text input '\(element.identifier)' to exist within \(timeout) seconds.",
                file: file,
                line: line
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && waitForElementToBecomeHittable(element, timeout: 0.5) {
                func tapAndWaitForFocus(_ action: () -> Void) -> Bool {
                    action()
                    return waitForElementKeyboardFocus(element, timeout: 1)
                }

                if preferTrailingEdge, !element.frame.isEmpty {
                    if tapAndWaitForFocus({
                        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                    }) {
                        return
                    }
                } else if tapAndWaitForFocus({
                    element.tap()
                }) {
                    return
                }

                if !element.frame.isEmpty, tapAndWaitForFocus({
                    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }) {
                    return
                }

                if tapAndWaitForFocus({
                    element.doubleTap()
                }) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            waitForElementToBecomeHittable(element, timeout: 0),
            "Expected text input '\(element.identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForElementKeyboardFocus(element, timeout: 0.5),
            "Expected text input '\(element.identifier)' to gain keyboard focus within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Focuses a text-entry control that was already resolved by a prompt-specific helper.
     *
     * SwiftUI alerts and sheets can expose their text field briefly, then make a second
     * `waitForExistence` call hang while XCTest rebuilds the modal snapshot. Prompt-specific
     * resolvers already proved the field exists, so this path starts with the focus attempts.
     */
    func focusResolvedTextEntryElement(
        _ element: XCUIElement,
        preferTrailingEdge: Bool = false,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        focusTextEntryElement(
            element,
            preferTrailingEdge: preferTrailingEdge,
            requireExistencePreflight: false,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Focuses a prompt-owned text-entry control without polling `isHittable` or keyboard focus.

     SwiftUI prompt surfaces can occasionally stall XCTest while resolving broad alert or sheet
     snapshots after a prompt-specific resolver has already found the field. Native prompts can also
     time out while evaluating `hasKeyboardFocus`, so this helper only delivers focused-field taps;
     callers prove success by observing the committed prompt value.

     For prompt-owned fields that can stall while re-sampling the field itself, callers can provide
     a prompt-surface coordinate. That path intentionally avoids `exists` and `frame` checks on the
     text field after resolution.
     */
    func focusResolvedPromptTextEntryElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        preferTrailingEdge: Bool = false,
        promptTapCoordinate: (() -> XCUICoordinate?)? = nil,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let tapOffset = CGVector(dx: preferTrailingEdge ? 0.92 : 0.5, dy: 0.5)

        repeat {
            if let coordinate = promptTapCoordinate?() {
                coordinate.tap()
                return
            }

            let coordinate: XCUICoordinate
            if element.exists, !element.frame.isEmpty {
                coordinate = element.coordinate(withNormalizedOffset: tapOffset)
            } else {
                coordinate = app.coordinate(withNormalizedOffset: tapOffset)
            }
            coordinate.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if element.exists, !element.frame.isEmpty {
                return
            }
        } while Date() < deadline

        XCTAssertTrue(
            element.exists && !element.frame.isEmpty,
            "Expected prompt text input '\(element.identifier)' to expose a tappable frame within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one text-entry control to report keyboard focus.
     *
     * - Parameters:
     *   - element: Text field or search field expected to own keyboard focus.
     *   - timeout: Maximum time to keep polling before giving up.
     * - Returns: `true` when the element reports keyboard focus, otherwise `false`.
     * - Side effects:
     *   - repeatedly samples the element-scoped `hasKeyboardFocus` predicate so the helper can
     *     distinguish a visible prompt field from one that is still unfocused
     * - Failure modes: This helper cannot fail.
     */
    func waitForElementKeyboardFocus(
        _ element: XCUIElement,
        timeout: TimeInterval = 1
    ) -> Bool {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate.evaluate(with: element) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return predicate.evaluate(with: element)
    }

    /**
     Clears one text-entry control and verifies that the editable contents are empty afterward.
     *
     * - Parameters:
     *   - element: Text field or search field whose contents should be removed.
     *   - app: Running application hosting the keyboard/edit menu.
     * - Returns: `true` when the helper confirms the field is empty.
     * - Side effects:
     *   - focuses the field, taps the standard clear control when available, otherwise deletes the
     *     visible contents from the trailing edge and finally falls back to the edit menu
     * - Failure modes: This helper does not fail directly.
     */
    func clearTextEntryElement(
        _ element: XCUIElement,
        app: XCUIApplication,
        placeholderHints: [String] = [],
        includeElementMetadata: Bool = true
    ) -> Bool {
        let existingText = currentTextEntryValue(
            in: element,
            placeholderHints: placeholderHints,
            includeElementMetadata: includeElementMetadata
        )
        if existingText.isEmpty {
            focusTextEntryElement(element, timeout: 10)
            return true
        }

        focusTextEntryElement(element, preferTrailingEdge: true, timeout: 10)

        var remainingText = existingText
        for _ in 0..<2 where !remainingText.isEmpty {
            let deleteSequence = String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: remainingText.count
            )
            app.typeText(deleteSequence)
            remainingText = currentTextEntryValue(
                in: element,
                placeholderHints: placeholderHints,
                includeElementMetadata: includeElementMetadata
            )
            if remainingText.isEmpty {
                return true
            }
        }

        if selectAllTextIfAvailable(in: element, app: app) {
            let selectionLength = max(
                currentTextEntryValue(
                    in: element,
                    placeholderHints: placeholderHints,
                    includeElementMetadata: includeElementMetadata
                ).count,
                1
            )
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: selectionLength))
            if currentTextEntryValue(
                in: element,
                placeholderHints: placeholderHints,
                includeElementMetadata: includeElementMetadata
            ).isEmpty {
                return true
            }
        }

        return currentTextEntryValue(
            in: element,
            placeholderHints: placeholderHints,
            includeElementMetadata: includeElementMetadata
        ).isEmpty
    }

    /**
     Waits for one switch element to report the requested raw value.
     *
     * - Parameters:
     *   - element: Switch element whose accessibility value should be polled.
     *   - expectedValue: Raw switch value expected before the timeout expires.
     *   - timeout: Maximum time to keep polling before giving up.
     * - Returns: `true` when the switch reaches `expectedValue`, otherwise `false`.
     * - Side effects:
     *   - repeatedly samples the live XCUI switch value so delayed SwiftUI updates can settle
     * - Failure modes: This helper cannot fail.
     */
    func waitForSwitchValue(
        _ element: XCUIElement,
        toEqual expectedValue: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String) == expectedValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return (element.value as? String) == expectedValue
    }

    /**
     Toggles one switch element and retries with a second native tap when the first tap does not
     drive the underlying value change.
     *
     * - Parameters:
     *   - element: Switch element that should toggle.
     *   - expectedValue: Switch value expected after the toggle.
     *   - timeout: Maximum time to wait for the expected value before retrying/failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - performs one normal tap and, when needed, one more native tap on the same switch
     * - Failure modes:
     *   - records an XCTest failure when the switch never reaches `expectedValue`
     */
    func toggleSwitchReliably(
        _ element: XCUIElement,
        expectedValue: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapElementReliably(element, timeout: timeout, file: file, line: line)
        if waitForSwitchValue(element, toEqual: expectedValue, timeout: min(timeout, 2)) {
            return
        }

        XCTAssertTrue(
            waitForElementToBecomeHittable(element, timeout: min(timeout, 2)),
            "Expected switch '\(element.identifier)' to become hittable before retrying the toggle.",
            file: file,
            line: line
        )
        element.tap()
        XCTAssertTrue(
            waitForSwitchValue(element, toEqual: expectedValue, timeout: min(timeout, 2)),
            "Expected switch '\(element.identifier)' to reach value '\(expectedValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Toggles one settings switch through the production switch control itself.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production switch.
     *   - app: Running application under test.
     *   - expectedValue: Switch value expected after the toggle.
     *   - timeout: Maximum time to wait for the cell and switch to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the real switch accessibility surface and toggles it through
     *     `toggleSwitchReliably`
     * - Failure modes:
     *   - records an XCTest failure when neither the row nor the switch can drive the expected
     *     value change
     */
    func toggleSettingsSwitch(
        _ identifier: String,
        in app: XCUIApplication,
        expectedValue: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggle = app.switches[identifier].firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: timeout),
            "Expected switch '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        toggleSwitchReliably(toggle, expectedValue: expectedValue, timeout: timeout, file: file, line: line)
    }

    /**
     Toggles one Sync category switch through the production switch control, then waits for the
     exported Sync screen state to confirm the mutation.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production Sync category toggle.
     *   - app: Running application under test.
     *   - expectedTokens: Sync screen token values expected after the toggle.
     *   - timeout: Maximum time to wait for the switch interaction and screen-state mutation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the exported Sync screen state and stops once the requested token
     *     values appear
     *   - scrolls the Sync Settings form when needed and uses the real toggle control for each
     *     retry
     * - Failure modes:
     *   - records an XCTest failure if the switch never appears or if the Sync screen state does
     *     not reach the requested token after the interaction
     */
    func toggleSyncCategory(
        _ identifier: String,
        in app: XCUIApplication,
        expectedTokens: [String: String],
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggle = app.buttons[identifier].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if waitForElementToBecomeHittable(toggle, timeout: min(1, timeout)) {
                toggle.tap()
                waitForSyncState(
                    expectedTokens,
                    in: app,
                    timeout: timeout,
                    file: file,
                    line: line
                )
                return
            }
            let syncScreen = resolvedElement("syncSettingsScreen", in: app)
            if syncScreen?.exists == true {
                syncScreen?.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            toggle.exists,
            "Expected sync category control '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        let didBecomeHittable = waitForElementToBecomeHittable(toggle, timeout: 1)
        XCTAssertTrue(
            didBecomeHittable,
            "Expected sync category control '\(identifier)' to become hittable during the final 1-second retry.",
            file: file,
            line: line
        )
        guard didBecomeHittable else {
            return
        }
        toggle.tap()
        waitForSyncState(
            expectedTokens,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Toggles the real justify-text setting and treats the screen-level exported state as the
     authoritative mutation signal.
     *
     * - Parameters:
     *   - screen: Root Text Display screen element whose exported semantic state should change.
     *   - app: Running application under test.
     *   - expectedScreenToken: Screen accessibility token expected after the toggle.
     *   - timeout: Maximum time to keep retrying the real UI interaction.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly toggles the real justify-text switch and polls the exported screen state
     * - Failure modes:
     *   - records an XCTest failure if the switch never drives the screen state to the requested
     *     token within the timeout window
     */
    func toggleTextDisplayJustifySwitch(
        on screen: XCUIElement,
        in app: XCUIApplication,
        expectedScreenToken: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if (screen.value as? String)?.contains(expectedScreenToken) == true {
            return
        }
        let toggle = requireReachableTextDisplayButton(
            "textDisplayJustifyTextToggleButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        tapElementReliably(toggle, timeout: timeout, file: file, line: line)

        waitForElementValue(
            "textDisplaySettingsScreen",
            toContain: expectedScreenToken,
            in: app,
            timeout: 1,
            file: file,
            line: line
        )
    }

    /**
     Scrolls the flat Text Display settings surface toward rows below the visible viewport.
     *
     * - Parameter app: Running application under test.
     * - Side effects: Swipes the Text Display scroll view, falling back to an app-level swipe.
     * - Failure modes: Leaves scroll position unchanged when no scrollable surface accepts the gesture.
     */
    func revealTextDisplaySettingsLowerContent(in app: XCUIApplication) {
        if let textDisplayScrollView = resolvedElement("textDisplaySettingsScrollView", in: app),
           textDisplayScrollView.exists
        {
            textDisplayScrollView.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    /**
     Resolves a Text Display row button after scrolling the custom flat settings list into view.
     *
     * `TextDisplaySettingsView` uses a custom `ScrollView` to match Android's flat preference
     * surface. Unlike `Form`, offscreen rows can still exist in the accessibility tree before they
     * are visible, so tests must reveal the row before tapping it.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production row button.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep resolving and revealing the list.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The row button once XCTest reports a hittable activation point.
     * - Side effects: Scrolls Text Display lower content until the requested row is hittable.
     * - Failure modes: Records a test failure if the row never appears or never becomes hittable.
     */
    func requireReachableTextDisplayButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCandidate = app.buttons[identifier].firstMatch

        repeat {
            let button = app.buttons[identifier].firstMatch
            if button.exists {
                lastCandidate = button
                if waitForElementToBecomeHittable(button, timeout: 0.5) {
                    return button
                }
            }

            revealTextDisplaySettingsLowerContent(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            lastCandidate.exists,
            "Expected Text Display button '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForElementToBecomeHittable(lastCandidate, timeout: 1),
            "Expected Text Display button '\(identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        return lastCandidate
    }

    /**
     Scrolls the Sync Settings form toward controls below the currently visible viewport.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - swipes the Sync Settings root when it is resolved, otherwise falls back to an app-level
     *     upward swipe
     * - Failure modes:
     *   - leaves scroll position unchanged when no scrollable surface accepts the gesture
     */
    func revealSyncSettingsLowerContent(in app: XCUIApplication) {
        if let syncScreen = resolvedElement("syncSettingsScreen", in: app),
           syncScreen.exists
        {
            syncScreen.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    /**
     Resolves a Sync Settings button that may live in a lazily materialized SwiftUI form section.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production button.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep resolving and revealing the form.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved button once it is visible inside the Sync Settings viewport.
     * - Side effects:
     *   - scrolls Sync Settings lower content until the requested button materializes as a native
     *     button inside the visible form viewport
     * - Failure modes:
     *   - records an XCTest failure if the button never appears or never becomes visible
     */
    func requireReachableSyncSettingsButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let syncScreen = requireElement(
            "syncSettingsScreen",
            in: app,
            timeout: min(timeout, 5),
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        var lastCandidate = app.buttons[identifier].firstMatch

        repeat {
            let button = app.buttons[identifier].firstMatch
            if button.exists {
                lastCandidate = button
                if isElementVisible(button, within: syncScreen) {
                    return button
                }
            }

            revealSyncSettingsLowerContent(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            lastCandidate.exists,
            "Expected Sync Settings button '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            isElementVisible(lastCandidate, within: syncScreen),
            "Expected Sync Settings button '\(identifier)' to become visible within \(timeout) seconds.",
            file: file,
            line: line
        )
        return lastCandidate
    }

    /**
     Returns the opposite serialized switch value for one live XCUI switch.
     *
     * - Parameter element: Live switch element whose current value should be inverted.
     * - Returns: The expected value string after one successful toggle.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func toggledSwitchValue(for element: XCUIElement) -> String {
        switch (element.value as? String)?.lowercased() {
        case "1", "true", "on":
            return "0"
        default:
            return "1"
        }
    }

    /**
     Taps the NextCloud connection-test control until the exported status leaves the idle state.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep retrying the production button.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - scrolls the Sync Settings form until the real test-connection button is visible
     *   - taps the visible button and polls the compact Sync Settings export until the remote
     *     status changes
     * - Failure modes:
     *   - records an XCTest failure if the button never drives the exported remote status away
     *     from `idle`
     */
    func triggerSyncConnectionTest(
        in app: XCUIApplication,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = requireReachableSyncSettingsButton(
            "syncNextCloudTestConnectionButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let syncState = resolvedElementSemanticText("syncSettingsState", in: app),
               let statusValue = syncStateToken(named: "remoteStatus", in: syncState),
               statusValue != "idle"
            {
                return
            }

            tapElementReliably(button, timeout: 1, file: file, line: line)

            let settleDeadline = Date().addingTimeInterval(2)
            repeat {
                if let syncState = resolvedElementSemanticText("syncSettingsState", in: app),
                   let statusValue = syncStateToken(named: "remoteStatus", in: syncState),
                   statusValue != "idle"
                {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < settleDeadline
        } while Date() < deadline

        let finalState = resolvedElementSemanticText("syncSettingsState", in: app) ?? "nil"
        let finalStatus = syncStateToken(named: "remoteStatus", in: finalState) ?? "nil"
        XCTAssertNotEqual(
            finalStatus,
            "idle",
            "Expected syncSettingsState to report a non-idle remoteStatus within \(timeout) seconds after triggering a connection test. Final state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /// Reads one named token out of the compact sync-settings accessibility export.
    func syncStateToken(named tokenName: String, in state: String) -> String? {
        state
            .split(separator: ";")
            .map(String.init)
            .first(where: { $0.hasPrefix("\(tokenName)=") })?
            .split(separator: "=", maxSplits: 1)
            .dropFirst()
            .first
            .map(String.init)
    }

    /**
     Asserts that the compact sync-settings export exposes the expected backend and enabled tokens.
     *
     * - Parameters:
     *   - state: Semicolon-delimited Sync Settings accessibility export.
     *   - backend: Expected backend token value.
     *   - enabled: Expected enabled token value.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: none.
     * - Failure modes:
     *   - records an XCTest failure if either token is missing or has an unexpected value
     */
    func assertSyncState(
        _ state: String?,
        backend: String,
        enabled: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolvedState = state ?? "nil"
        XCTAssertEqual(
            syncStateToken(named: "backend", in: resolvedState),
            backend,
            "Expected sync backend token '\(backend)' in state '\(resolvedState)'.",
            file: file,
            line: line
        )
        XCTAssertEqual(
            syncStateToken(named: "enabled", in: resolvedState),
            enabled,
            "Expected sync enabled token '\(enabled)' in state '\(resolvedState)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits until the compact sync-settings export matches a set of named token values.
     *
     * - Parameters:
     *   - expectedTokens: Token names and expected values that must all be present.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to poll before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly reads the Sync Settings accessibility export until all requested token values
     *     match
     * - Failure modes:
     *   - records an XCTest failure if the requested token values never appear before timeout
     */
    func waitForSyncState(
        _ expectedTokens: [String: String],
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let stateElement = requireElement("syncSettingsState", in: app, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let state = stateElement.value as? String,
               expectedTokens.allSatisfy({ syncStateToken(named: $0.key, in: state) == $0.value })
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalState = stateElement.value as? String ?? "nil"
        let expectedDescription = expectedTokens
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        XCTFail(
            "Expected syncSettingsState to match '\(expectedDescription)' within \(timeout) seconds. Final state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /**
     Polls until one accessibility-identified element appears above another in the visible UI.
     *
     * - Parameters:
     *   - upperIdentifier: Accessibility identifier expected to resolve to the higher row.
     *   - lowerIdentifier: Accessibility identifier expected to resolve to the lower row.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy for both identifiers until their visible
     *     frames settle into the requested vertical order
     *   - records an XCTest failure when the requested order never appears before timeout
     * - Failure modes:
     *   - fails when either element disappears or when the requested vertical ordering never
     *     materializes within the timeout window
     */
    func waitForElement(
        _ upperIdentifier: String,
        toAppearAbove lowerIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let upperElement = unresolvedElement(upperIdentifier, in: app)
            let lowerElement = unresolvedElement(lowerIdentifier, in: app)
            if upperElement.exists,
               lowerElement.exists,
               upperElement.frame.minY < lowerElement.frame.minY {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalUpperElement = unresolvedElement(upperIdentifier, in: app)
        let finalLowerElement = unresolvedElement(lowerIdentifier, in: app)
        XCTAssertTrue(
            finalUpperElement.exists && finalLowerElement.exists &&
                finalUpperElement.frame.minY < finalLowerElement.frame.minY,
            "Expected '\(upperIdentifier)' to appear above '\(lowerIdentifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }
}
