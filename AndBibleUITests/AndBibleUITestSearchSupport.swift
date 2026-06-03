import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func openSearch(in app: XCUIApplication) -> XCUIElement {
        if app.launchArguments.contains("-UITEST_SEARCH_QUERY"),
           let prePresentedSearch = waitForSearchScreenIfAlreadySeeded(in: app, timeout: 10) {
            waitForSearchInteractionReady(on: prePresentedSearch, in: app, timeout: 120)
            return prePresentedSearch
        }

        tapReaderSearchEntry(in: app, timeout: 15)
        let searchScreen = requireSearchScreen(in: app, timeout: 20)
        waitForSearchInteractionReady(on: searchScreen, in: app, timeout: 120)
        return searchScreen
    }

    /// Reuses a Search sheet that the app auto-presented from a launch-seeded UI-test query.
    func waitForSearchScreenIfAlreadySeeded(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let searchScreen = resolvedElement("searchScreen", in: app) {
                return searchScreen
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
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
     Resolves the root Search screen element without forcing XCTest through incorrect typed queries.
     *
     * SwiftUI can expose this surface as different automation classes across runtimes, so Search
     * must not go through the generic identifier resolver that still reasons in terms of buttons,
     * links, or scroll views. This helper only asks XCTest for any element carrying the stable
     * `searchScreen` identifier and returns the first live match.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first live Search root node exporting the `searchScreen` identifier.
     * - Side effects:
     *   - polls the live accessibility hierarchy until Search is presented
     * - Failure modes:
     *   - records an XCTest failure if Search never presents a root node within the timeout
     */
    func requireSearchScreen(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let screen = resolvedSearchScreenElement(in: app) {
                return screen
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let screen = unresolvedElement("searchScreen", in: app)
        XCTAssertTrue(
            screen.exists,
            "Expected Search to present its root state element within \(timeout) seconds.",
            file: file,
            line: line
        )
        return screen
    }

    /**
     Waits for the Search screen to report that its current query is no longer in flight.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - timeout: Maximum time to wait for the `state=ready;searching=false` state.
     * - Side effects:
     *   - blocks the current XCTest method until the search state reports ready completion or
     *     times out
     * - Failure modes:
     *   - fails the test if the Search screen never reports `state=ready;searching=false`
     *     before the timeout
     */
    func waitForSearchToFinish(in app: XCUIApplication, timeout: TimeInterval) {
        waitForSearchState(containing: "", in: app, timeout: timeout)
    }

    /**
     Waits for Search to become interactive and triggers index creation when the screen reports
     that the active module needs one.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the Search accessibility value until it reports `state=ready`
     *   - taps the visible `Create` button when Search reports `state=needsIndex`
     * - Failure modes:
     *   - records an XCTest failure if Search never becomes interactive within the timeout window
     */
    func waitForSearchInteractionReady(
        on searchScreen: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let state = resolvedSearchStateValue(in: app) ?? (searchScreen.value as? String ?? "")
            if state.contains("state=ready") {
                return
            }
            let createButton = resolveSearchCreateIndexButton(in: app)
            if state.contains("state=needsIndex")
                || createButton.exists
                || createButton.waitForExistence(timeout: 0.2)
            {
                tapElementReliably(createButton, timeout: 10, file: file, line: line)
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail(
            "Expected Search to become interactive within \(timeout) seconds.",
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
        func matches(_ value: String) -> Bool {
            value.contains("state=ready")
                && value.contains("searching=false")
                && value.contains(token)
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if searchStateCandidateValues(in: app).contains(where: matches) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        let finalValues = searchStateCandidateValues(in: app)
        if finalValues.contains(where: matches) {
            return
        }

        let lastValue = finalValues.isEmpty ? "nil" : finalValues.joined(separator: " || ")
        XCTFail(
            "Expected Search state to contain '\(token)' within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for Search to report at least one settled result row count.
     *
     * - Parameters:
     *   - minimumCount: Inclusive lower bound for the exported `results=` count.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait before failing.
     * - Side effects:
     *   - polls the Search accessibility export until it reports `state=ready;searching=false`
     *     with a parsed result count at or above `minimumCount`
     * - Failure modes:
     *   - fails the test if Search never publishes a large-enough settled count
     */
    func waitForSearchResultCount(
        atLeast minimumCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               let count = searchResultCount(from: value),
               count >= minimumCount {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        let lastValue = resolvedSearchStateValue(in: app) ?? "nil"
        XCTFail(
            "Expected Search to report at least \(minimumCount) results within \(timeout) seconds; last value was '\(lastValue)'."
        )
    }

    /// Parses the deterministic `results=` token from Search accessibility state.
    func searchResultCount(from state: String) -> Int? {
        guard let range = state.range(of: "results=") else { return nil }
        let suffix = state[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /**
     Waits for Search to expose a selected-module set matching one semantic predicate.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait before failing.
     *   - description: Human-readable predicate description for failure output.
     *   - predicate: Assertion predicate applied to the parsed selected-module set.
     * - Side effects:
     *   - polls the Search accessibility export until it reaches a settled ready state
     * - Failure modes:
     *   - fails when Search never publishes a selected-module set matching `predicate`
     */
    func waitForSearchSelectedModules(
        in app: XCUIApplication,
        timeout: TimeInterval,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (Set<String>) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               let modules = searchSelectedModules(from: value),
               predicate(modules) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        let lastValue = resolvedSearchStateValue(in: app) ?? "nil"
        XCTFail(
            "Expected Search selected modules to match \(description) within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /// Parses the deterministic `selectedModules=` token from Search accessibility state.
    func searchSelectedModules(from state: String) -> Set<String>? {
        guard let range = state.range(of: "selectedModules=") else { return nil }
        let suffix = state[range.upperBound...]
        let token = suffix.prefix { $0 != ";" }
        return Set(token.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// Taps the first visible module row inside the real module picker sheet.
    func tapFirstModulePickerRow(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        _ = requireElement("modulePickerScreen", in: app, timeout: timeout, file: file, line: line)
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "modulePickerRow::")
        let candidates = [
            app.buttons.matching(predicate).firstMatch,
            app.collectionViews.buttons.matching(predicate).firstMatch,
            app.collectionViews.cells.matching(predicate).firstMatch,
            app.cells.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = candidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) }) {
                tapElementReliably(row, timeout: timeout, file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected module picker to expose at least one 'modulePickerRow::' row within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Taps one visible button by its accessibility label and waits for it to become hittable.
     *
     * - Parameters:
     *   - label: Visible accessibility label expected on the target button.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the button to exist and become
     *     hittable.
     * - Side effects:
     *   - resolves the requested button from the visible button hierarchy and taps its center
     *     point directly
     * - Failure modes:
     *   - fails if the button never appears or never becomes hittable within the timeout
     */
    func tapButtonLabeled(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected visible button '\(label)' to exist within \(timeout) seconds."
        )
        tapElementReliably(button, timeout: timeout)
    }

    /**
     Taps one Search scope button through its stable accessibility identifier.
     *
     * - Parameters:
     *   - scopeToken: Stable Search scope token exported by `SearchView`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the scope button to exist and become
     *     hittable.
     * - Side effects:
     *   - resolves the requested Search scope button from the accessibility hierarchy and taps
     *     its center point directly; callers verify the resulting Search state separately
     * - Failure modes:
     *   - fails if the requested scope button never appears or never becomes hittable within the
     *     allotted timeout
     */
    func tapSearchScope(
        _ scopeToken: SearchScopeToken,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let identifier = "searchScopeButton::\(scopeToken.rawValue)"

        while Date() < deadline {
            dismissSearchFieldFocusIfNeeded(in: app)
            revealSearchControls(in: app)

            let searchScreen = unresolvedElement("searchScreen", in: app)
            let scopeStrip = resolvedElement("searchScopeStrip", in: app)
                ?? searchScreen.scrollViews["searchScopeStrip"].firstMatch
            let candidates = [
                scopeStrip.buttons[identifier].firstMatch,
                scopeStrip.otherElements[identifier].firstMatch,
                searchScreen.buttons[identifier].firstMatch,
                searchScreen.otherElements[identifier].firstMatch,
            ]

            if let identifierElement = candidates.first(where: {
                ($0.exists || $0.waitForExistence(timeout: 0.2))
                    && waitForElementToBecomeHittable($0, timeout: 0.5)
            }) {
                tapElementReliably(identifierElement, timeout: 3)
                return
            }

            if scopeStrip.exists, !scopeStrip.frame.isEmpty {
                if let candidate = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                    if candidate.frame.minX < scopeStrip.frame.minX {
                        scopeStrip.swipeRight()
                    } else {
                        scopeStrip.swipeLeft()
                    }
                } else {
                    scopeStrip.swipeLeft()
                    scopeStrip.swipeRight()
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Expected Search scope button '\(scopeToken.fallbackLabel)' to exist within \(timeout) seconds.")
    }

    /**
     Opens the Search translation picker through its stable Search options control.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the picker affordance.
     * - Side effects:
     *   - reveals Search options when needed and taps the translation picker button
     * - Failure modes:
     *   - fails when the translation picker affordance does not open the picker
     */
    func tapSearchTranslationPicker(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if searchTranslationPickerIsOpen(in: app, timeout: 0.2) {
                return
            }

            dismissSearchFieldFocusIfNeeded(in: app)
            revealSearchControls(in: app)
            let searchScreen = unresolvedElement("searchScreen", in: app)
            let candidates = [
                searchScreen.buttons["searchTranslationPickerButton"].firstMatch,
                searchScreen.otherElements["searchTranslationPickerButton"].firstMatch,
                app.buttons["searchTranslationPickerButton"].firstMatch,
                app.otherElements["searchTranslationPickerButton"].firstMatch,
            ]

            if let picker = candidates.first(where: {
                ($0.exists || $0.waitForExistence(timeout: 0.2))
                    && waitForElementToBecomeHittable($0, timeout: 0.5)
            }) {
                tapElementReliably(picker, timeout: 2)
                if searchTranslationPickerIsOpen(in: app, timeout: 3) {
                    return
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Search translation picker to open within \(timeout) seconds.")
    }

    /**
     Returns true once the Search translation picker sheet has exposed any stable child element.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Total time budget for polling the candidate set.
     * - Returns: `true` when a picker-specific Done button or picker list exists.
     * - Side effects:
     *   - polls the live accessibility hierarchy while SwiftUI presents or dismisses the picker
     * - Failure modes: This helper does not fail directly.
     */
    func searchTranslationPickerIsOpen(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))

        repeat {
            if firstExistingElement(searchTranslationPickerOpenCandidates(in: app), timeout: 0) != nil {
                return true
            }
            if timeout <= 0 {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return firstExistingElement(searchTranslationPickerOpenCandidates(in: app), timeout: 0) != nil
    }

    /// Returns stable picker descendants that prove the Search translation picker sheet is open.
    func searchTranslationPickerOpenCandidates(in app: XCUIApplication) -> [XCUIElement] {
        searchTranslationDoneCandidates(in: app, includeLocalizedFallbacks: false)
            + searchTranslationPickerListCandidates(in: app)
    }

    /**
     Toggles one module row in the Search translation picker.
     *
     * - Parameters:
     *   - moduleName: Stable module abbreviation, such as `UITESTWEB`.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the row.
     * - Side effects:
     *   - taps the matching translation row
     * - Failure modes:
     *   - fails when the picker does not expose the requested row
     */
    func tapSearchTranslationRow(
        moduleName: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let identifier = "searchTranslationRow::\(moduleName)"
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let row = firstExistingElement(
                searchTranslationRowCandidates(identifier, moduleName: moduleName, in: app),
                timeout: 0.2
            ) {
                let expectedValue = expectedSearchTranslationRowValue(afterTapping: row)
                if waitForElementToBecomeHittable(row, timeout: 1),
                   elementHasUsableFrame(row) {
                    row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
                } else {
                    tapElementReliably(row, timeout: 1)
                }
                waitForSearchTranslationRowMutation(
                    identifier: identifier,
                    moduleName: moduleName,
                    expectedValue: expectedValue,
                    in: app,
                    timeout: min(3, timeout)
                )
                return
            }

            if let pickerList = firstExistingElement(searchTranslationPickerListCandidates(in: app), timeout: 0.1),
               pickerList.exists {
                pickerList.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Search translation row '\(moduleName)' to exist within \(timeout) seconds.")
    }

    /// Returns list roots for the Search translation picker.
    func searchTranslationPickerListCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let identifier = "searchTranslationPickerList"
        return [
            app.collectionViews[identifier].firstMatch,
            app.tables[identifier].firstMatch,
            app.scrollViews[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Returns scoped Done button candidates for the Search translation picker.
     *
     * SwiftUI can expose toolbar buttons through navigation bars, toolbars, sheets, or finally the
     * app-wide button query depending on runtime. The helper keeps the app-wide query as a fallback
     * only, because broad button snapshots are the least stable while the picker list is refreshing
     * after a translation row toggles.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - includeLocalizedFallbacks: Whether to include generic localized Done buttons after the
     *     stable identifier candidates. Picker-open checks pass `false` to avoid matching keyboard
     *     or unrelated toolbar Done controls before the translation picker is open.
     * - Returns: Ordered button candidates, from picker-scoped surfaces to broad fallbacks.
     * - Side effects: none.
     * - Failure modes: This helper does not fail directly.
     */
    func searchTranslationDoneCandidates(
        in app: XCUIApplication,
        includeLocalizedFallbacks: Bool = true
    ) -> [XCUIElement] {
        let identifiedCandidates = [
            app.navigationBars.buttons["searchTranslationDoneButton"].firstMatch,
            app.toolbars.buttons["searchTranslationDoneButton"].firstMatch,
            app.sheets.buttons["searchTranslationDoneButton"].firstMatch,
            app.buttons["searchTranslationDoneButton"].firstMatch,
        ]
        guard includeLocalizedFallbacks else {
            return identifiedCandidates
        }
        return identifiedCandidates + [
            app.navigationBars.buttons["Done"].firstMatch,
            app.toolbars.buttons["Done"].firstMatch,
            app.sheets.buttons["Done"].firstMatch,
            app.buttons["Done"].firstMatch,
        ]
    }

    /**
     Determines the semantic accessibility value expected after one translation-row tap.
     *
     * - Parameter row: The row element that is about to be tapped.
     * - Returns: `selected` or `unselected` when the row exposes a known pre-tap value; otherwise
     *   `nil` so callers only wait for picker stability.
     * - Side effects: none.
     * - Failure modes: This helper does not fail directly.
     */
    func expectedSearchTranslationRowValue(afterTapping row: XCUIElement) -> String? {
        switch row.value as? String {
        case "selected":
            return "unselected"
        case "unselected":
            return "selected"
        default:
            return nil
        }
    }

    /**
     Waits for a translation-row tap to settle before the picker toolbar is queried again.
     *
     * The grouped multi-translation search test toggles a row, which triggers SwiftUI to re-render
     * the list and starts a background search rerun. Waiting for either the row accessibility value
     * to update or the picker list to remain visible prevents the next step from querying toolbar
     * buttons during the most volatile part of that transition.
     *
     * - Parameters:
     *   - identifier: Stable row accessibility identifier.
     *   - moduleName: Module abbreviation displayed by the row.
     *   - expectedValue: Optional post-tap accessibility value to wait for.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the mutation to settle.
     * - Side effects:
     *   - polls the live picker accessibility hierarchy while SwiftUI settles row state
     * - Failure modes: This helper does not fail directly; downstream assertions still validate
     *   the selected-module Search state.
     */
    func waitForSearchTranslationRowMutation(
        identifier: String,
        moduleName: String,
        expectedValue: String?,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(max(0, timeout))

        repeat {
            if let row = firstExistingElement(
                searchTranslationRowCandidates(identifier, moduleName: moduleName, in: app),
                timeout: 0.1
            ) {
                if let expectedValue, row.value as? String == expectedValue {
                    return
                }
                if expectedValue == nil, elementHasUsableFrame(row) {
                    return
                }
            }

            if expectedValue == nil,
               firstExistingElement(searchTranslationPickerListCandidates(in: app), timeout: 0.1) != nil {
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        } while Date() < deadline
    }

    /// Returns row candidates for one Search translation picker module.
    func searchTranslationRowCandidates(
        _ identifier: String,
        moduleName: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let scoped = searchTranslationPickerListCandidates(in: app).flatMap { list in
            [
                list.buttons[identifier].firstMatch,
                list.cells[identifier].firstMatch,
                list.otherElements[identifier].firstMatch,
                list.staticTexts[moduleName].firstMatch,
            ]
        }
        return scoped + [
            app.buttons[identifier].firstMatch,
            app.collectionViews.buttons[identifier].firstMatch,
            app.cells[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
            app.staticTexts[moduleName].firstMatch,
        ]
    }

    /**
     Selects every module in the Search translation picker.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the toolbar action.
     * - Side effects:
     *   - taps the picker toolbar Search All action
     * - Failure modes:
     *   - fails when the Search All action is not reachable
     */
    func tapSearchTranslationSelectAll(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let selectAll = app.buttons["searchTranslationSelectAllButton"].firstMatch
        if selectAll.waitForExistence(timeout: timeout) {
            tapElementReliably(selectAll, timeout: timeout)
            return
        }

        let fallbackSelectAll = app.buttons["All"].firstMatch
        XCTAssertTrue(
            fallbackSelectAll.waitForExistence(timeout: timeout),
            "Expected Search translation All button to exist within \(timeout) seconds."
        )
        tapElementReliably(fallbackSelectAll, timeout: timeout)
    }

    /**
     Closes the Search translation picker.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the Done action.
     * - Side effects:
     *   - taps the picker toolbar Done action
     * - Failure modes:
     *   - fails when the Done action is not reachable
     */
    func tapSearchTranslationDone(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let done = firstExistingElement(searchTranslationDoneCandidates(in: app), timeout: 0.2) {
                tapElementReliably(done, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow)))
                if !searchTranslationPickerIsOpen(in: app, timeout: 2) {
                    return
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Search translation Done button to exist within \(timeout) seconds.")
    }

    /**
     Taps one Search word-mode control while staying scoped to the live Search screen.
     *
     * - Parameters:
     *   - label: Visible segmented-control label, such as `Phrase` or `Any Word`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - resolves the mode control from Search's visible hierarchy and taps it directly
     * - Failure modes:
     *   - fails if the requested mode control never appears on Search within the timeout
     */
    func tapSearchWordMode(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            dismissSearchFieldFocusIfNeeded(in: app)
            revealSearchControls(in: app)
            let searchScreen = unresolvedElement("searchScreen", in: app)

            if let token = searchWordModeToken(forVisibleLabel: label) {
                let identifier = "searchWordModeButton::\(token)"
                let identifierCandidates = [
                    searchScreen.buttons[identifier].firstMatch,
                    searchScreen.otherElements[identifier].firstMatch,
                    searchScreen.segmentedControls["searchWordModePicker"].buttons[label].firstMatch,
                    searchScreen.segmentedControls.buttons[label].firstMatch,
                    app.buttons[identifier].firstMatch,
                    app.otherElements[identifier].firstMatch,
                    app.segmentedControls["searchWordModePicker"].buttons[label].firstMatch,
                    app.segmentedControls.buttons[label].firstMatch,
                ]
                for candidate in identifierCandidates where candidate.exists || candidate.waitForExistence(timeout: 0.2) {
                    tapElementReliably(candidate, timeout: timeout)
                    return
                }
            }

            if let segmentIndex = searchWordModeSegmentIndex(forVisibleLabel: label),
               let picker = [
                   searchScreen.segmentedControls["searchWordModePicker"].firstMatch,
                   searchScreen.otherElements["searchWordModePicker"].firstMatch,
               ].first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) })
            {
                tapSegmentedControlSegment(
                    picker,
                    index: segmentIndex,
                    segmentCount: SearchWordModeControl.segmentCount,
                    timeout: timeout
                )
                return
            }

            let fallbackCandidates = [
                searchScreen.segmentedControls.buttons[label].firstMatch,
                searchScreen.buttons[label].firstMatch,
                app.segmentedControls.buttons[label].firstMatch,
                app.buttons[label].firstMatch,
            ]
            for candidate in fallbackCandidates where candidate.exists || candidate.waitForExistence(timeout: 0.2) {
                tapElementReliably(candidate, timeout: timeout)
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Search mode button '\(label)' to exist within \(timeout) seconds.")
    }

    /**
     Maps one visible Search word-mode label to the stable accessibility token exported by Search.
     *
     * - Parameter label: Visible segmented-control label used by the UI test.
     * - Returns: Stable production token for the requested label, or `nil` when the label is
     *   unknown to the test harness.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func searchWordModeToken(forVisibleLabel label: String) -> String? {
        switch label {
        case "All Words":
            return "allWords"
        case "Any Word":
            return "anyWord"
        case "Phrase":
            return "phrase"
        default:
            return nil
        }
    }

    /**
     Maps one visible Search word-mode label to its deterministic segment index within the Search
     segmented control.
     *
     * - Parameter label: Visible segmented-control label used by the UI test.
     * - Returns: Zero-based segment index for the requested label, or `nil` when the label is
     *   unknown to the test harness.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func searchWordModeSegmentIndex(forVisibleLabel label: String) -> Int? {
        switch label {
        case "All Words":
            return 0
        case "Any Word":
            return 1
        case "Phrase":
            return 2
        default:
            return nil
        }
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
     *   - falls back to a brief run-loop advance when no visible Search scroll surface exists
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

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    /**
     Moves focus away from the active Search field so the lower Search option rows can surface.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - uses one visible keyboard dismissal action when the software keyboard remains presented
     *     after query submission
     * - Failure modes:
     *   - silently leaves focus unchanged when no keyboard dismissal action is available
     */
    func dismissSearchFieldFocusIfNeeded(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists || keyboard.waitForExistence(timeout: 0.2) else {
            return
        }

        dismissKeyboardIfPresent(in: app)
        guard keyboard.exists else {
            return
        }
        let searchScreen = unresolvedElement("searchScreen", in: app)
        let dismissalCandidates = [
            searchScreen.buttons["searchWordModeButton::allWords"].firstMatch,
            searchScreen.otherElements["searchWordModeButton::allWords"].firstMatch,
            searchScreen.segmentedControls["searchWordModePicker"].buttons["All Words"].firstMatch,
            searchScreen.segmentedControls.buttons["All Words"].firstMatch,
            searchScreen.buttons["All Words"].firstMatch
        ]
        for candidate in dismissalCandidates where candidate.exists && !candidate.frame.isEmpty {
            tapElementReliably(candidate, timeout: 5)
            return
        }

        let pickerCandidates = [
            searchScreen.segmentedControls["searchWordModePicker"].firstMatch,
            searchScreen.otherElements["searchWordModePicker"].firstMatch,
        ]
        if let picker = pickerCandidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) }) {
            tapSegmentedControlSegment(
                picker,
                index: 0,
                segmentCount: SearchWordModeControl.segmentCount,
                timeout: 5
            )
        }
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
     *   - shouldExist: Whether the result row is expected to exist by the timeout.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live XCUI hierarchy until the requested row reaches the requested existence
     *     state
     * - Failure modes:
     *   - records an XCTest failure if the row never reaches the requested existence state
     */
    func waitForSearchResultRow(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let rowToken = "|\(identifier)|"

        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               value.contains(rowToken) == shouldExist {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedSearchStateValue(in: app) ?? ""
        XCTAssertEqual(
            finalValue.contains(rowToken),
            shouldExist,
            "Expected Search result '\(identifier)' existence to become \(shouldExist) within \(timeout) seconds. Final Search state: '\(finalValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Extracts the exported numeric result count from the Search accessibility state token.
     *
     * - Parameter searchState: Semicolon-delimited Search screen state string.
     * - Returns: Parsed result count, or `-1` when the token is missing or malformed.
     * - Side effects: none.
     * - Failure modes:
       - returns `-1` when the Search screen accessibility export changes shape unexpectedly
     */
    func searchResultsCount(from searchState: String) -> Int {
        guard let resultsToken = searchState
            .split(separator: ";")
            .first(where: { $0.hasPrefix("results=") }) else {
            return -1
        }
        return Int(resultsToken.dropFirst("results=".count)) ?? -1
    }

    /**
     Resolves the first tappable Search result row exported by the current Search screen.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the first result row to materialize.
     * - Returns: First matching Search result row element.
     * - Side effects:
     *   - queries the live accessibility hierarchy for any identifier prefixed with
     *     `searchResultRow::`
     * - Failure modes:
     *   - fails when the Search screen exports no tappable result rows before the timeout
     */
    func requireFirstSearchResultRow(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "searchResultRow::")
        let candidates = [
            app.collectionViews.buttons.matching(predicate).firstMatch,
            app.collectionViews.cells.matching(predicate).firstMatch,
            app.buttons.matching(predicate).firstMatch,
            app.cells.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let result = candidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) }) {
                return result
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected at least one search result row within \(timeout) seconds.")
        return candidates.first ?? app.otherElements["searchResultRow::missing"].firstMatch
    }

}
