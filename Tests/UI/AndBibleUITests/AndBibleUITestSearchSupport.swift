import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

private let seededSearchFixtureScenarios: Set<String> = [
    "locked-picker-downloads",
    "search-indexed",
]

/// Maximum Search readiness wait for fixture-seeded Search UI tests.
private let seededSearchReadinessTimeout: TimeInterval = 20

/// Maximum Search readiness wait for workflows that intentionally create an index at runtime.
private let runtimeSearchIndexReadinessTimeout: TimeInterval = 120

extension AndBibleUITests {
    /**
     Opens Search and waits for it to become interactive under the current fixture contract.

     Normal Search UI tests use the `search-indexed` fixture scenario from
     `Tests/UI/Fixtures/ui_test_fixture_manifest.json`. That scenario must be detected by the app as
     already indexed and must not enter `state=needsIndex`; otherwise the test is hiding a fixture
     regression behind runtime index creation and long readiness waits. Intentional runtime
     index-creation coverage should use a non-seeded fixture path and test that workflow explicitly.

     - Parameters:
       - app: Running application under test.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: The visible Search root element after the readiness contract is satisfied.
     - Side effects:
       - presents Search through the reader action surface
       - polls Search's accessibility state until the screen is ready
       - fails immediately for seeded Search fixtures if Search asks to create an index
     - Failure modes:
       - records an XCTest failure when Search does not present or does not become interactive
       - records an XCTest failure when a seeded Search fixture exposes `state=needsIndex`
     */
    func openSearch(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let fixtureScenario = resolveFixtureScenario(
            environment: ProcessInfo.processInfo.environment,
            file: file,
            line: line
        )
        let isSeededSearchFixtureScenario = fixtureScenario.map {
            seededSearchFixtureScenarios.contains($0)
        } ?? false
        let allowsRuntimeIndexCreation = !isSeededSearchFixtureScenario
        let readinessTimeout = searchReadinessTimeout(
            allowsRuntimeIndexCreation: allowsRuntimeIndexCreation
        )

        let searchScreen = presentSearchFromReader(in: app, timeout: 20, file: file, line: line)
        waitForSearchInteractionReady(
            on: searchScreen,
            in: app,
            timeout: readinessTimeout,
            allowsRuntimeIndexCreation: allowsRuntimeIndexCreation,
            file: file,
            line: line
        )
        return searchScreen
    }

    /**
     Selects the Search readiness budget for the current index lifecycle contract.

     Normal Search UI tests launch with seeded `search-indexed` fixtures and should only need the
     same short readiness budget used by the follow-up Search assertions. A longer budget remains
     available for explicit runtime index-creation coverage so that fixture-backed tests do not hide
     regressions behind Android-incompatible automatic indexing.

     - Parameter allowsRuntimeIndexCreation: Whether the current workflow may create a missing
       Search index at runtime.
     - Returns: The readiness timeout to pass to `waitForSearchInteractionReady`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func searchReadinessTimeout(allowsRuntimeIndexCreation: Bool) -> TimeInterval {
        allowsRuntimeIndexCreation
            ? runtimeSearchIndexReadinessTimeout
            : seededSearchReadinessTimeout
    }

    /**
     Presents Search from the reader shell and verifies that the app actually entered Search state.

     The adaptive SwiftUI toolbar can expose multiple Search button candidates while `ViewThatFits`
     settles. This helper chooses the production entry surface once, performs one action, and then
     passively waits for the Search root. Reader state remains diagnostic context rather than an
     alternate success path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum seconds to spend across direct and drawer activation paths.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The visible Search root once presentation is confirmed.
     * - Side effects:
     *   - taps the direct reader Search affordance
     *   - passively polls the Search root after that single action
     * - Failure modes:
     *   - records an XCTest failure when the chosen production activation does not present Search
     */
    func presentSearchFromReader(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        tapReaderSearchEntry(in: app, timeout: min(10, timeout), file: file, line: line)
        let didPresentSearch = waitForUITestCondition(
            "Wait for Search presentation after one entry action",
            timeout: max(0, timeout)
        ) {
            self.resolvedSearchScreenElement(in: app) != nil
        }
        let searchScreen = unresolvedElement("searchScreen", in: app)
        XCTAssertTrue(
            didPresentSearch && searchScreen.exists,
            "Expected one Search entry action to present the visible Search root within \(timeout) seconds; passive reader state was '\(resolvedElementSemanticText("readerRenderedContentState", in: app) ?? "nil")'.",
            file: file,
            line: line
        )
        return searchScreen
    }

    /**
     Opens Search from the most stable production reader affordance available on the current shell.
     *
     * Search can appear both as a direct toolbar button and as a drawer action. The UI harness
     * should prefer the direct toolbar button when it is already visible instead of forcing the
     * drawer path and paying the extra surface-recovery cost.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the direct toolbar Search action when it is already visible on the reader shell
     *   - otherwise falls back to the shared reader-action routing helper
     * - Failure modes:
     *   - records an XCTest failure if neither the direct button nor the routed action can be
     *     opened within the allotted timeout
     */
    func tapReaderSearchEntry(
        in app: XCUIApplication,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if waitForReaderShellReady(in: app, timeout: min(10, timeout)),
           resolvedElement("readerNavigationDrawer", in: app) == nil,
           resolvedElement("readerOverflowMenu", in: app) == nil
        {
            let directCandidates = [
                app.otherElements["readerDocumentHeader"].buttons["readerSearchButton"].firstMatch,
                app.otherElements["readerDocumentHeader"].buttons["Search"].firstMatch,
                app.buttons["readerSearchButton"].firstMatch,
                app.buttons["readerOpenSearchAction"].firstMatch,
                app.buttons["Search"].firstMatch,
            ]

            if let directButton = directCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                tapElementReliably(directButton, timeout: timeout, file: file, line: line)
                return
            }
        }

        tapReaderAction("readerOpenSearchAction", in: app, timeout: timeout, file: file, line: line)
    }

    /**
     Submits the retained Search criteria once through the currently focused control.

     - Parameters:
       - app: Running application under test.
       - timeout: Maximum time to resolve the visible submit command when the field lacks focus.
     - Side effects: Activates Android's keyboard Search action when the query field owns focus;
       otherwise taps the criteria activity's bottom Search command. The caller observes its
       expected outcome: a reference can leave Search, while an indexed query displays results.
     - Failure modes: Records an XCTest failure when the active submit path is unavailable.
     */
    func submitSearchCriteria(
        in app: XCUIApplication,
        timeout: TimeInterval = 20
    ) {
        if searchFieldFocusIsActive(in: app) {
            app.typeText(XCUIKeyboardKey.return.rawValue)
            return
        }

        let submitButton = requireElement("searchSubmitButton", in: app, timeout: timeout)
        tapElementReliably(submitButton, timeout: timeout)
    }

    /**
     Waits for the compact Search state export through the shared semantic-state waiter.

     Search publishes a deterministic `searchStateExport` value for UI tests. This helper keeps
     Search-specific callers on one observation path while preserving each caller's predicate and
     failure wording.

     - Parameters:
       - app: Running application under test.
       - timeout: Maximum time to wait before failing.
       - success: Predicate that must match the exported Search state.
       - failureDescription: Closure that formats the failure message from the final observed
         Search state.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Side effects:
       - polls the shared Search accessibility export through `waitForResolvedSemanticState`
     - Failure modes:
       - records an XCTest failure with the final Search state when the predicate never matches
     */
    func waitForSearchSemanticState(
        in app: XCUIApplication,
        timeout: TimeInterval,
        success: @escaping (String) -> Bool,
        failureDescription: (String) -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: "searchStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedSearchStateValue(in: app) },
            success: success,
            failureDescription: failureDescription,
            file: file,
            line: line
        )
    }

    /**
     Waits for Search to become interactive and optionally triggers runtime index creation.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - allowsRuntimeIndexCreation: Whether this workflow is allowed to tap the runtime index
     *     creation prompt when Search reports `state=needsIndex`.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the Search accessibility value until it reports `state=ready`
     *   - taps the visible `Create` button only when runtime index creation is allowed
     * - Failure modes:
     *   - records an XCTest failure if Search never becomes interactive within the timeout window
     *   - records an XCTest failure immediately when runtime index creation is disallowed and
     *     Search reports `state=needsIndex` or exposes the Create-index prompt, including which
     *     signal was observed
     */
    func waitForSearchInteractionReady(
        on searchScreen: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        allowsRuntimeIndexCreation: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastState = "nil"
        var observedNeedsIndex = false
        var observedCreatePrompt = false
        func failSeededFixtureReadiness() {
            let indexCreationRequested = observedNeedsIndex || observedCreatePrompt
            XCTFail(
                "Expected seeded Search fixture to be ready without runtime index creation; "
                    + "last Search state was '\(lastState)'; "
                    + "state=needsIndex observed=\(observedNeedsIndex); "
                    + "index creation requested=\(indexCreationRequested); "
                    + "Create-index prompt observed=\(observedCreatePrompt).",
                file: file,
                line: line
            )
        }

        while Date() < deadline {
            let state = resolvedSearchStateValue(in: app) ?? ""
            if !state.isEmpty {
                lastState = state
            }
            if state.contains("state=ready") {
                return
            }
            let sawNeedsIndex = state.contains("state=needsIndex")
            if sawNeedsIndex {
                observedNeedsIndex = true
                if !allowsRuntimeIndexCreation {
                    failSeededFixtureReadiness()
                    return
                }
                let createButton = resolveSearchCreateIndexButton(in: app)
                observedCreatePrompt = true
                tapElementReliably(createButton, timeout: 10, file: file, line: line)
                continue
            }

            let createButton = resolveSearchCreateIndexButton(in: app)
            let sawCreatePrompt = createButton.exists || createButton.waitForExistence(timeout: 0.2)
            if sawCreatePrompt {
                observedCreatePrompt = true
                if !allowsRuntimeIndexCreation {
                    failSeededFixtureReadiness()
                    return
                }
                tapElementReliably(createButton, timeout: 10, file: file, line: line)
                continue
            }
            _ = waitForUITestCondition(
                "Wait for Search readiness state",
                timeout: min(0.5, max(0, deadline.timeIntervalSinceNow))
            ) {
                let state = self.resolvedSearchStateValue(in: app) ?? ""
                if !state.isEmpty {
                    lastState = state
                }
                if state.contains("state=ready") || state.contains("state=needsIndex") {
                    observedNeedsIndex = observedNeedsIndex || state.contains("state=needsIndex")
                    return true
                }
                let createButton = self.resolveSearchCreateIndexButton(in: app)
                if createButton.exists {
                    observedCreatePrompt = true
                    return true
                }
                return false
            }
        }

        let indexCreationRequested = observedNeedsIndex || observedCreatePrompt
        XCTFail(
            "Expected Search to become interactive within \(timeout) seconds; "
                + "last Search state was '\(lastState)'; "
                + "state=needsIndex observed=\(observedNeedsIndex); "
                + "index creation requested=\(indexCreationRequested); "
                + "Create-index prompt observed=\(observedCreatePrompt).",
            file: file,
            line: line
        )
    }

    /**
     Waits for the Search screen to report a settled state containing one expected semantic token.
     *
     * - Parameters:
     *   - token: State fragment expected once the current search rerun has completed.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for `state=ready;searching=false` with the requested token.
     * - Side effects:
     *   - re-resolves the live `searchScreen` element until its accessibility value reports the
     *     requested settled state or the timeout expires
     * - Failure modes:
     *   - fails the test if the Search screen never reaches the requested settled state
     */
    func waitForSearchState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForSearchSemanticState(
            in: app,
            timeout: timeout,
            success: {
                $0.contains("state=ready")
                    && $0.contains("searching=false")
                    && $0.contains(token)
            },
            failureDescription: {
                "Expected Search state to contain '\(token)' within \(timeout) seconds; last value was '\($0)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Reveals Search option controls that may be hidden behind the active search field or list
     scroll position.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - swipes the Search results container or another visible scrollable Search surface
     *     downward to bring scope controls back into view
     * - Failure modes:
     *   - falls back to a brief predicate wait when no visible Search scroll surface exists
     */
    func revealSearchControls(in app: XCUIApplication) {
        let searchScreen = unresolvedElement("searchScreen", in: app)
        let optionsPanel = searchScreen.otherElements["searchOptionsPanel"].firstMatch
        if optionsPanel.exists || optionsPanel.waitForExistence(timeout: 0.2) {
            return
        }

        let optionsToggle = app.buttons["searchOptionsToggleButton"].firstMatch
        if optionsToggle.exists || optionsToggle.waitForExistence(timeout: 0.2) {
            let toggleValue = String(describing: optionsToggle.value ?? "")
            if toggleValue.localizedCaseInsensitiveContains("hidden") {
                tapElementReliably(optionsToggle, timeout: 5)
                if optionsPanel.waitForExistence(timeout: 2) {
                    return
                }
            }
        }
        let scrollableCandidates: [XCUIElement] = [
            unresolvedElement("searchResultsList", in: app),
            searchScreen.collectionViews["searchResultsList"].firstMatch,
            searchScreen.tables["searchResultsList"].firstMatch,
            searchScreen.scrollViews["searchResultsList"].firstMatch,
        ]

        if let visibleScrollable = scrollableCandidates.first(where: {
            $0.exists && !$0.frame.isEmpty
        }) {
            for _ in 0..<2 {
                visibleScrollable.swipeDown()
                if optionsPanel.exists || optionsPanel.waitForExistence(timeout: 0.5) {
                    return
                }
            }
        }

        _ = waitForUITestCondition(
            "Wait for Search controls after reveal",
            timeout: 0.2
        ) {
            optionsPanel.exists
        }
    }

    /**
     Reads the Search field focus state from the compact UI-test state export.

     The focus state is part of the Search screen contract because option controls can be obscured by
     the keyboard, but probing `searchQueryField.exists` has repeatedly wedged XCTest snapshots in CI.
     Keeping the decision on the state export lets controls that are already unfocused proceed without
     touching the text-field hierarchy at all.
     *
     * - Parameter app: Running application under test.
     * - Returns: `true` when the Search export reports `searchFieldFocused=true`.
     * - Side effects: none.
     * - Failure modes: returns `false` when Search has not exported state yet.
     */
    func searchFieldFocusIsActive(in app: XCUIApplication) -> Bool {
        searchFieldFocusState(in: app) == true
    }

    /**
     Resolves the Search field focus token from the compact UI-test state export.

     - Parameter app: Running application under test.
     - Returns: `true` for `searchFieldFocused=true`, `false` for `searchFieldFocused=false`, or
       `nil` when Search has not exported either token.
     - Side effects: none.
     - Failure modes: returns `nil` when the Search state export is temporarily absent.
     */
    func searchFieldFocusState(in app: XCUIApplication) -> Bool? {
        for value in searchStateCandidateValues(in: app) {
            if value.contains("searchFieldFocused=true") {
                return true
            }
            if value.contains("searchFieldFocused=false") {
                return false
            }
        }
        return nil
    }

    /**
     Waits for the exported Search state to retain one expected query string.
     *
     * - Parameters:
     *   - expectedQuery: Query string expected to remain in Search after the screen opens.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the compact production Search state export until it contains the expected query
     * - Failure modes:
     *   - records an XCTest failure if the Search state never exposes the expected query before
     *     timeout
     */
    func waitForSearchQuery(
        _ expectedQuery: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForSearchState(
            containing: "query=\(expectedQuery)",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Waits for one deterministic Search result row to either appear or disappear.
     *
     * - Parameters:
     *   - identifier: Stable result-row accessibility identifier.
     *   - app: Running application under test.
     *   - shouldExist: Whether the result row is expected to be visibly rendered by the timeout.
     *   - expectedContent: User-visible label fragments the rendered row must expose.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live XCUI hierarchy until the requested row reaches the requested visibility
     *     and content state
     * - Failure modes:
     *   - records an XCTest failure if the row never reaches the requested existence state
     */
    func waitForSearchResultRow(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        expectedContent: [String] = [],
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastVisibleContent = "<row unavailable>"
        let reachedExpectedState = waitForUITestCondition(
            "Wait for visible Search result \(identifier)",
            timeout: max(0, timeout)
        ) {
            guard let searchState = self.resolvedSearchStateValue(in: app),
                  searchState.contains("state=ready"),
                  searchState.contains("searching=false") else {
                lastVisibleContent = "<Search has not settled>"
                return false
            }
            guard let row = self.firstExistingElement(
                self.searchResultRowCandidates(identifier, in: app),
                timeout: 0
            ) else {
                lastVisibleContent = "<row unavailable>"
                return !shouldExist
            }
            guard shouldExist else {
                lastVisibleContent = "<row still exists>"
                return false
            }

            let intersection = row.frame.intersection(app.frame)
            guard self.elementHasUsableFrame(row),
                  !intersection.isNull,
                  !intersection.isEmpty else {
                lastVisibleContent = "<row has no visible geometry>"
                return false
            }
            let semanticContent = [row.label, row.value as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            lastVisibleContent = semanticContent.isEmpty ? "<row has no visible content>" : semanticContent
            return expectedContent.allSatisfy {
                semanticContent.localizedCaseInsensitiveContains($0)
            }
        }
        XCTAssertTrue(
            reachedExpectedState,
            "Expected Search result '\(identifier)' visible state to become \(shouldExist) with content \(expectedContent) within \(timeout) seconds; last visible content was '\(lastVisibleContent)', passive Search state was '\(resolvedSearchStateValue(in: app) ?? "nil")'.",
            file: file,
            line: line
        )
    }

    /**
     Selects a Search result row and waits for that selection to navigate the reader.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the expected `searchResultRow::` control.
     *   - initialReference: Reader reference value captured before opening or using Search.
     *   - app: Running application under test.
     *   - timeout: Maximum time for the result selection to change the reader reference.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: First non-empty reader reference value that differs from `initialReference`.
     * - Side effects:
     *   - taps the live, visibly rendered Search result row exactly once
     *   - passively waits for the reader reference to change after the action
     * - Failure modes:
     *   - fails if the row cannot be tapped or if Search dismisses/settles without changing the
     *     reader reference
     */
    func tapSearchResultRowAndWaitForReaderReferenceChange(
        _ identifier: String,
        from initialReference: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        waitForSearchResultRow(
            identifier,
            in: app,
            shouldExist: true,
            timeout: timeout,
            file: file,
            line: line
        )
        guard let row = firstExistingElement(
            searchResultRowCandidates(identifier, in: app),
            timeout: 0
        ) else {
            XCTFail(
                "Expected visible Search result '\(identifier)' before its single selection action.",
                file: file,
                line: line
            )
            return initialReference
        }
        tapElementReliably(row, timeout: timeout, file: file, line: line)
        return waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

}
