import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func heuristicElementCandidates(
        for identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        if identifier.hasSuffix("Screen") {
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
                app.navigationBars[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Field") {
            return [
                app.searchFields[identifier].firstMatch,
                app.textFields[identifier].firstMatch,
                app.secureTextFields[identifier].firstMatch,
                app.textViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Button")
            || identifier.contains("Button::")
            || identifier.hasSuffix("Action")
        {
            return [
                app.buttons[identifier].firstMatch,
                app.navigationBars.buttons[identifier].firstMatch,
                app.toolbars.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.cells.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Toggle") {
            return [
                app.switches[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Link") {
            return [
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Picker") {
            return [
                app.segmentedControls[identifier].firstMatch,
                app.pickers[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Menu") || identifier.contains("Menu::") {
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasSuffix("Label")
            || identifier.hasSuffix("Title")
            || identifier.hasSuffix("Status")
        {
            return [
                app.staticTexts[identifier].firstMatch,
                app.navigationBars.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.contains("Row::") {
            return [
                app.collectionViews.cells[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        return [app.otherElements[identifier].firstMatch]
    }

    /// Returns the minimal set of root containers that can own one screen-scoped identifier.
    func screenRootCandidates(
        _ identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        [
            app.collectionViews[identifier].firstMatch,
            app.tables[identifier].firstMatch,
            app.scrollViews[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Resolves button-like candidates by searching inside one owning screen before falling back to
     app-wide queries.

     This keeps XCTest from repeatedly snapshotting the full hierarchy for controls that only ever
     exist inside a known screen, which has been a recurring CI timeout source.
     */
    func screenScopedButtonCandidates(
        _ identifier: String,
        within screenIdentifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let scopedCandidates = screenRootCandidates(screenIdentifier, in: app).flatMap { root in
            [
                root.buttons[identifier].firstMatch,
                root.cells.buttons[identifier].firstMatch,
                root.otherElements[identifier].firstMatch,
            ]
        }

        return scopedCandidates + [
            app.buttons[identifier].firstMatch,
            app.navigationBars.buttons[identifier].firstMatch,
            app.toolbars.buttons[identifier].firstMatch,
            app.collectionViews.buttons[identifier].firstMatch,
            app.cells.buttons[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Resolves row-like candidates by searching inside one owning screen before falling back to
     app-wide queries.
     */
    func screenScopedRowCandidates(
        _ identifier: String,
        within screenIdentifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let scopedCandidates = screenRootCandidates(screenIdentifier, in: app).flatMap { root in
            [
                root.cells[identifier].firstMatch,
                root.buttons[identifier].firstMatch,
                root.otherElements[identifier].firstMatch,
            ]
        }

        return scopedCandidates + [
            app.collectionViews.cells[identifier].firstMatch,
            app.cells[identifier].firstMatch,
            app.buttons[identifier].firstMatch,
            app.collectionViews.buttons[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Resolves Search result rows inside the Search sheet/list before using any broader fallback.

     Search result UI tests already wait for the compact Search state export before tapping a row.
     Keeping the row query scoped avoids repeated full-app snapshots across the underlying reader
     web view, which can time out in CI while the result list itself is already settled.
     */
    func searchResultRowCandidates(
        _ identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let roots = screenRootCandidates("searchResultsList", in: app) +
            screenRootCandidates("searchScreen", in: app)

        return roots.flatMap { root in
            [
                root.buttons[identifier].firstMatch,
                root.cells[identifier].firstMatch,
                root.otherElements[identifier].firstMatch,
            ]
        }
    }

    /**
     Resolves lightweight state-export or status candidates without probing broad `Other` queries.

     The app emits these probes as tiny static text nodes specifically so polling their value does
     not force XCTest to snapshot unrelated SwiftUI containers.
     */
    func screenScopedStateCandidates(
        _ identifier: String,
        within screenIdentifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let directCandidates = [
            app.staticTexts[identifier].firstMatch,
        ]
        let scopedCandidates = screenRootCandidates(screenIdentifier, in: app).flatMap { root in
            [
                root.staticTexts[identifier].firstMatch,
            ]
        }

        return directCandidates + scopedCandidates
    }

    /**
     Returns state-bearing elements in the order safest for repeated value polling.
     *
     * Screen roots are preferred when they publish the same accessibility value and the screen is
     * stable because reading a known root avoids enumerating every `StaticText` in dynamic lists.
     * Transition-prone surfaces use the direct hidden export so a temporarily absent root does not
     * register an XCTest snapshot failure during polling.
     */
    func semanticStateValueCandidates(
        for identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        switch identifier {
        case "searchStateExport":
            return [
                app.otherElements["searchScreen"].firstMatch,
            ] + screenScopedStateCandidates(identifier, within: "searchScreen", in: app)
        case "bookmarkListStateExport":
            return screenRootCandidates("bookmarkListScreen", in: app)
                + screenScopedStateCandidates(identifier, within: "bookmarkListScreen", in: app)
        case "readingPlanListStateExport":
            return [
                app.staticTexts[identifier].firstMatch,
            ]
        case "availablePlansStateExport":
            return screenRootCandidates("availablePlansScreen", in: app)
                + screenScopedStateCandidates(identifier, within: "availablePlansScreen", in: app)
        case "labelManagerStateExport":
            return screenScopedStateCandidates(identifier, within: "labelManagerScreen", in: app)
        case "syncSettingsState":
            return screenRootCandidates("syncSettingsScreen", in: app)
                + screenScopedStateCandidates(identifier, within: "syncSettingsScreen", in: app)
        default:
            return semanticStateCandidates(for: identifier, in: app)
        }
    }

    /// Returns the first modal presentation surface currently visible to XCTest.
    func resolvedModalPrompt(
        in app: XCUIApplication,
        timeout: TimeInterval = 0.2
    ) -> XCUIElement? {
        let candidates = [
            app.alerts.firstMatch,
            app.sheets.firstMatch,
        ]
        return firstExistingElement(candidates, timeout: timeout)
    }

    /// Finds the first existing element from a deliberately small candidate list.
    func firstExistingElement(
        _ candidates: [XCUIElement],
        timeout: TimeInterval = 0
    ) -> XCUIElement? {
        let boundedTimeout = max(0, timeout)
        for candidate in candidates {
            if candidate.exists {
                return candidate
            }
            if boundedTimeout > 0,
               candidate.waitForExistence(timeout: boundedTimeout)
            {
                return candidate
            }
        }
        return nil
    }

    /**
     Returns modal-owned text field candidates in the order XCTest resolves SwiftUI prompts most
     consistently: visible placeholder/title first, then ordinal field, then accessibility id.
     */
    func modalTextFieldCandidates(
        in prompt: XCUIElement,
        identifiers: [String] = [],
        titles: [String] = []
    ) -> [XCUIElement] {
        let titledCandidates = titles.flatMap { title in
            [
                prompt.textFields[title].firstMatch,
                prompt.secureTextFields[title].firstMatch,
            ]
        }
        let ordinalCandidates = [
            prompt.textFields.element(boundBy: 0),
            prompt.secureTextFields.element(boundBy: 0),
        ]
        let identifiedCandidates = identifiers.flatMap { identifier in
            [
                prompt.textFields[identifier].firstMatch,
                prompt.secureTextFields[identifier].firstMatch,
            ]
        }
        return titledCandidates + ordinalCandidates + identifiedCandidates
    }

    /// Returns modal-owned button candidates without falling back to the full app hierarchy.
    func modalButtonCandidates(
        in prompt: XCUIElement,
        identifiers: [String] = [],
        titles: [String] = []
    ) -> [XCUIElement] {
        let titledCandidates = titles.map { prompt.buttons[$0].firstMatch }
        let identifiedCandidates = identifiers.map { prompt.buttons[$0].firstMatch }
        return titledCandidates + identifiedCandidates
    }

    /// Returns the currently focused text-entry candidates for custom prompt sheets.
    func focusedTextEntryCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let focusedPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        return [
            app.textFields.matching(focusedPredicate).firstMatch,
            app.secureTextFields.matching(focusedPredicate).firstMatch,
            app.descendants(matching: .any).matching(focusedPredicate).firstMatch,
        ]
    }

    /**
     Returns observable workspace-name prompt container candidates.
     *
     * - Parameter app: Running application under test.
     * - Returns: The SwiftUI accessibility container used by the custom workspace-name prompt.
     * - Side effects: none.
     * - Failure modes:
     *   This helper cannot fail; callers decide whether absence is expected. It intentionally avoids
     *   absent table, collection, and scroll containers because hosted XCTest can stall while proving
     *   those broad SwiftUI queries do not exist before it reaches the real prompt node.
     */
    func workspaceNamePromptScreenCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let identifier = "workspaceNamePromptScreen"
        return [
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Returns workspace-name prompt text-field candidates without probing arbitrary fields.

     SwiftUI can expose the workspace prompt field by its visible title while custom identifier
     text-field queries intermittently wedge XCTest snapshot resolution on hosted simulators. The
     candidate list therefore stays bounded to title lookups and scoped title fallbacks; it
     deliberately avoids prompt-root descendant scans, app-wide focused-field queries, and the
     custom-id text-field lookup that can stall before the prompt has fully settled.
     */
    func workspaceNamePromptTextFieldCandidates(in app: XCUIApplication) -> [XCUIElement] {
        let titledCandidates = ["Name", "name"].flatMap { title in
            [
                app.textFields[title].firstMatch,
                app.collectionViews.textFields[title].firstMatch,
                app.tables.textFields[title].firstMatch,
                app.scrollViews.textFields[title].firstMatch,
            ]
        }
        return titledCandidates
    }

    /// Returns workspace-name prompt buttons without walking the custom sheet hierarchy.
    func workspaceNamePromptButtonCandidates(
        _ identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let titles: [String]
        switch identifier {
        case "workspaceNamePromptConfirmButton":
            titles = ["Create", "create", "Save", "save"]
        case "workspaceNamePromptCancelButton":
            titles = ["Cancel", "cancel"]
        default:
            titles = []
        }

        let directIdentifierCandidates = [
            app.navigationBars.buttons[identifier].firstMatch,
            app.toolbars.buttons[identifier].firstMatch,
            app.buttons[identifier].firstMatch,
            app.collectionViews.buttons[identifier].firstMatch,
            app.tables.buttons[identifier].firstMatch,
            app.scrollViews.buttons[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
        let directTitleCandidates = titles.map { title in
            app.buttons[title].firstMatch
        }
        return directIdentifierCandidates + directTitleCandidates
    }

    /// Returns screen-aware candidates for small exported semantic state controls.
    func semanticStateCandidates(
        for identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        switch identifier {
        case "searchStateExport":
            return screenScopedStateCandidates(identifier, within: "searchScreen", in: app)
        case "bookmarkListStateExport":
            return screenScopedStateCandidates(identifier, within: "bookmarkListScreen", in: app)
        case "readingPlanListStateExport":
            return screenScopedStateCandidates(identifier, within: "readingPlanListScreen", in: app)
        case "availablePlansStateExport":
            return screenScopedStateCandidates(identifier, within: "availablePlansScreen", in: app)
        case "labelManagerStateExport":
            return screenScopedStateCandidates(identifier, within: "labelManagerScreen", in: app)
        case "syncSettingsState":
            return screenScopedStateCandidates(identifier, within: "syncSettingsScreen", in: app)
        default:
            return [
                app.staticTexts[identifier].firstMatch,
            ]
        }
    }

    /**
     Produces the minimal ordered set of XCUI queries for one accessibility identifier.
     *
     * This helper is intentionally explicit for recurring screen/container roots. The earlier
     * generic "try every XCUI type" approach was the main source of CI flakiness because it could
     * resolve the wrong class for a screen root and force XCTest into very expensive cross-type
     * snapshot evaluation.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: One narrow ordered set of queries for the requested identifier.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func elementCandidates(
        for identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        if identifier.hasPrefix("labelAssignmentRow::") {
            return screenScopedRowCandidates(identifier, within: "labelAssignmentScreen", in: app)
        }

        if identifier.hasPrefix("labelAssignmentToggleButton::")
            || identifier.hasPrefix("labelAssignmentFavouriteButton::")
        {
            return screenScopedButtonCandidates(identifier, within: "labelAssignmentScreen", in: app)
        }

        if identifier.hasPrefix("bookmarkListFilterChip::") {
            return screenScopedButtonCandidates(identifier, within: "bookmarkListScreen", in: app)
        }

        if identifier.hasPrefix("bookmarkListOpenStudyPadButton::") {
            return screenScopedButtonCandidates(identifier, within: "bookmarkListScreen", in: app)
        }

        if identifier.hasPrefix("bookmarkListEditLabelsButton::")
            || identifier.hasPrefix("bookmarkListRowButton::")
        {
            return screenScopedButtonCandidates(identifier, within: "bookmarkListScreen", in: app)
        }

        if identifier.hasPrefix("bookmarkListDeleteButton::")
            || identifier.hasPrefix("readingPlanDeleteButton::")
            || identifier.hasPrefix("historyDeleteButton::")
            || identifier.hasPrefix("bookmarkListSortOption::")
        {
            return [
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.cells.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasPrefix("searchResultRow::") {
            return searchResultRowCandidates(identifier, in: app)
        }

        if identifier.hasPrefix("windowTabButton::") {
            return [
                app.scrollViews["windowTabBar"].buttons[identifier].firstMatch,
                app.otherElements["windowTabBar"].buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasPrefix("modulePickerRow::") {
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        switch identifier {
        case "readerNavigationDrawer":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerNavigationDrawerDismissArea":
            return [
                app.otherElements[identifier].firstMatch,
            ]
        case "readerNavigationDrawerButton":
            return [
                app.otherElements["readerDocumentHeader"].buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerMoreMenuButton", "bookChooserButton":
            return [
                app.otherElements["readerDocumentHeader"].buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerStrongsToolbarButton":
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerBibleToolbarButton", "readerCommentaryToolbarButton":
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                app.images[identifier].firstMatch,
            ]
        case "windowTabAddButton":
            return [
                app.scrollViews["windowTabBar"].buttons[identifier].firstMatch,
                app.otherElements["windowTabBar"].buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerStudyPadTitle", "readerMyNotesTitle":
            return [
                app.staticTexts[identifier].firstMatch,
                app.navigationBars.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerReturnFromMyNotesButton", "readerReturnFromStudyPadButton":
            return [
                app.buttons[identifier].firstMatch,
                app.navigationBars.buttons[identifier].firstMatch,
            ]
        case "readerRenderedContentState":
            return [
                app.textFields[identifier].firstMatch,
            ]
        case "readerOverflowMenu":
            return [
                app.otherElements[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
            ]
        case "readerOverflowMenuDismissArea":
            return [
                app.otherElements[identifier].firstMatch,
            ]
        case "readerOverflowSectionTitlesToggle":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Section Titles"].firstMatch,
                app.buttons["Section titles"].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerOverflowStrongsModeAction":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Strong's Numbers…"].firstMatch,
                app.buttons["Strong's Numbers..."].firstMatch,
                app.buttons["Strong's numbers…"].firstMatch,
                app.buttons["Strong's numbers..."].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerOverflowVerseNumbersToggle":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Chapter & Verse Numbers"].firstMatch,
                app.buttons["Chapter & verse numbers"].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "labelAssignmentCreateNewLabelButton":
            return screenScopedButtonCandidates(identifier, within: "labelAssignmentScreen", in: app)
        case "labelManagerNewLabelNameField":
            var candidates: [XCUIElement] = []
            if let prompt = resolvedLabelCreationPrompt(in: app) {
                candidates += labelCreationPromptTextFieldCandidates(in: prompt)
            }
            candidates += appScopedLabelCreationPromptTextFieldCandidates(in: app)
            return candidates
        case "labelEditNameField":
            return [
                app.textFields[identifier].firstMatch,
                app.textViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "labelManagerCreateButton":
            var candidates: [XCUIElement] = []
            if let prompt = resolvedLabelCreationPrompt(in: app) {
                candidates += labelCreationPromptCreateButtonCandidates(in: prompt)
            }
            candidates += appScopedLabelCreationPromptCreateButtonCandidates(in: app)
            return candidates
        case "colorSettingsResetButton":
            return screenScopedButtonCandidates(identifier, within: "colorSettingsScreen", in: app)
        case "aboutAppTitle":
            return [
                app.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutDoneButton", "labelAssignmentDoneButton", "bookmarkListDoneButton":
            return [
                app.buttons[identifier].firstMatch,
                app.navigationBars.buttons[identifier].firstMatch,
                app.toolbars.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutScreen":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutSheetScreen":
            return [
                app.navigationBars[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchScreen":
            // Search exports its live state on an accessibility Other root; scoped helpers use
            // unresolvedElement("searchScreen") before probing child controls.
            return [
                app.otherElements[identifier].firstMatch,
                app.collectionViews[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
            ]
        case
            "searchStateExport",
            "bookmarkListStateExport",
            "readingPlanListStateExport",
            "availablePlansStateExport",
            "labelManagerStateExport":
            return semanticStateCandidates(for: identifier, in: app)
        case "searchResultsList":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchScopeStrip":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchWordModePicker":
            return [
                app.segmentedControls[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchQueryField":
            return [
                app.textFields[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                app.navigationBars.textFields[identifier].firstMatch,
                app.searchFields[identifier].firstMatch,
                app.navigationBars.searchFields[identifier].firstMatch,
            ]
        case "workspaceNamePromptTextField":
            return workspaceNamePromptTextFieldCandidates(in: app)
        case "workspaceNamePromptConfirmButton", "workspaceNamePromptCancelButton":
            return workspaceNamePromptButtonCandidates(identifier, in: app)
        case
            "settingsDownloadsLink",
            "settingsRepositoriesLink",
            "settingsImportExportLink",
            "settingsSyncLink",
            "settingsReadingProgressLink",
            "settingsLabelsLink":
            return [
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "syncSettingsState":
            return semanticStateCandidates(for: identifier, in: app)
        case "textDisplayColorsLink", "textDisplayFontFamilyButton":
            return [
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "textDisplayJustifyTextToggle":
            return [
                app.switches[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "textDisplaySettingsScreen":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "textDisplaySettingsScrollView":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case
            "settingsForm",
            "bookmarkListScreen",
            "labelAssignmentScreen",
            "labelManagerScreen",
            "labelEditScreen",
            "syncSettingsScreen",
            "readingProgressSettingsScreen",
            "colorSettingsScreen",
            "importExportScreen",
            "modulePickerScreen",
            "moduleBrowserScreen":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "workspaceNamePromptScreen":
            return workspaceNamePromptScreenCandidates(in: app)
        case "historyScreen", "readingPlanListScreen", "availablePlansScreen":
            return [
                app.tables[identifier].firstMatch,
                app.collectionViews[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "workspaceSelectorScreen":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readingPlanTemplateButton":
            return screenScopedButtonCandidates(identifier, within: "availablePlansScreen", in: app)
        case "readingPlanImportButton":
            return screenScopedButtonCandidates(identifier, within: "availablePlansScreen", in: app)
        case "readingPlanStartButton", "readingPlanActivePlanLink":
            return screenScopedButtonCandidates(identifier, within: "readingPlanListScreen", in: app)
        default:
            return heuristicElementCandidates(for: identifier, in: app)
        }
    }

    /**
     Resolves the first live typed XCUI element for one accessibility identifier.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: The first existing typed candidate in the explicit priority order.
     * - Side effects: none.
     * - Failure modes: returns `nil` when the identifier is not currently exposed.
     */
    func resolvedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let candidates = elementCandidates(for: identifier, in: app)
        return candidates.first(where: { $0.exists })
    }

    /// Resolves a tiny hidden UI-test state export without broad fallbacks into unrelated hierarchies.
    func resolvedStateExportElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let candidates = semanticStateCandidates(for: identifier, in: app)
        return candidates.first(where: { $0.exists })
    }

    /**
     Returns a stable fallback query for one accessibility identifier without forcing broad queries.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: The first typed candidate for the identifier.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func unresolvedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        elementCandidates(for: identifier, in: app).first ?? app.otherElements[identifier].firstMatch
    }

    /**
     Waits for an accessibility-identified element and records a precise failure when it never appears.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching UI element for the requested accessibility identifier.
     * - Side effects:
     *   - queries the live XCUI hierarchy repeatedly until the timeout expires
     *   - records an XCTest assertion failure when no matching element appears in time
     * - Failure modes:
     *   - returns the unresolved query result after recording a failure when the identifier never appears
     */
    func requireElement(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = resolvedElement(identifier, in: app) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let element = unresolvedElement(identifier, in: app)
        XCTAssertTrue(
            element.exists,
            "Expected element '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the first accessibility-identified element in a candidate set to appear.
     *
     * - Parameters:
     *   - identifiers: Ordered accessibility identifiers to probe.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to keep polling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching visible element, or `nil` when none appear before timeout.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy across the provided identifiers
     * - Failure modes: This helper does not fail directly.
     */
    func waitForAnyElement(
        _ identifiers: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in identifiers {
                if let candidate = resolvedElement(identifier, in: app) {
                    return candidate
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
    }

    /**
     Waits for one bookmark-list row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - referenceSegment: Identifier-safe reference segment such as `Exodus_2_1`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved bookmark-row element.
     * - Side effects:
     *   - queries the live accessibility hierarchy for the requested bookmark row identifier
     * - Failure modes:
     *   - records an XCTest failure if the bookmark row never appears within the timeout
     */
    func requireBookmarkRow(
        _ referenceSegment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireElement(
            "bookmarkListRowButton::\(referenceSegment)",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Waits for one visible History row whose accessible label contains the requested reference text.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the visible History row label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved History row element.
     * - Side effects:
     *   - queries both button and generic accessibility elements for the visible History row label
     * - Failure modes:
     *   - records an XCTest failure if no matching History row appears within the timeout
     */
    func requireHistoryRow(
        containing fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        let candidates = [
            app.buttons.matching(predicate).firstMatch,
            app.collectionViews.buttons.matching(predicate).firstMatch,
            app.collectionViews.cells.matching(predicate).firstMatch,
            app.cells.matching(predicate).firstMatch,
            app.staticTexts.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = candidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) }) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            false,
            "Expected a History row containing '\(fragment)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return candidates.first ?? app.otherElements["historyRow::missing"].firstMatch
    }

    /**
     Resolves the first visible accessibility element whose label contains a reader reference token.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the rendered reader reference.
     *   - app: Running application under test.
     * - Returns: Matching UI element query result.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func readerReferenceElement(
        containing fragment: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: 0.5) {
            return referenceButton
        }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        let candidates = [
            app.navigationBars.buttons.matching(predicate).firstMatch,
            app.navigationBars.staticTexts.matching(predicate).firstMatch,
            app.buttons.matching(predicate).firstMatch,
            app.staticTexts.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
        ]
        return candidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) })
            ?? app.otherElements[fragment].firstMatch
    }

    /**
     Waits for the visible reader chrome to expose a reference label containing the requested token.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the rendered reader reference.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Matching UI element.
     * - Side effects:
     *   - queries the live XCUI hierarchy until a matching element appears
     * - Failure modes:
     *   - records an XCTest failure when no matching visible reference appears in time
     */
    func requireReaderReferenceContaining(
        _ fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: min(timeout, 1)) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let value = referenceButton.value as? String,
                   value.localizedCaseInsensitiveContains(fragment)
                {
                    return referenceButton
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline

            let finalValue = referenceButton.value as? String ?? ""
            XCTAssertTrue(
                finalValue.localizedCaseInsensitiveContains(fragment),
                "Expected the reader reference to contain '\(fragment)' within \(timeout) seconds, but saw '\(finalValue)'.",
                file: file,
                line: line
            )
            return referenceButton
        }

        let element = readerReferenceElement(containing: fragment, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected a visible reader reference containing '\(fragment)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the visible reader chrome to stop exposing a stale reference label.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected to disappear after navigation.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the matching UI element until it no longer exists
     * - Failure modes:
     *   - records an XCTest failure when the stale reference remains visible after the timeout
     */
    func waitForReaderReferenceToDisappear(
        _ fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: min(timeout, 1)) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let value = referenceButton.value as? String ?? ""
                if !value.localizedCaseInsensitiveContains(fragment) {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline

            let finalValue = referenceButton.value as? String ?? ""
            XCTAssertFalse(
                finalValue.localizedCaseInsensitiveContains(fragment),
                "Expected the reader reference to stop containing '\(fragment)' within \(timeout) seconds, but saw '\(finalValue)'.",
                file: file,
                line: line
            )
            return
        }

        let element = readerReferenceElement(containing: fragment, in: app)
        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            element.exists,
            "Expected reader reference containing '\(fragment)' to disappear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the primary reader reference control to expose a non-empty value.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The current non-empty reader reference string from `bookChooserButton`.
     * - Side effects:
     *   - polls the live reader toolbar until the reference control exports one non-empty value
     * - Failure modes:
     *   - records an XCTest failure if the reader reference never becomes non-empty
     */
    func requireReaderReferenceValue(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let referenceButton = requireButton(
            "bookChooserButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = referenceButton.value as? String, !value.isEmpty {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallbackValue = referenceButton.value as? String ?? ""
        XCTAssertFalse(
            fallbackValue.isEmpty,
            "Expected bookChooserButton to expose a non-empty reader reference within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallbackValue
    }

    /**
     Waits for the active reader pane's rendered-content export to contain one semantic token.
     */
    func waitForReaderRenderedContentState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = readerRenderedContentStateValue(in: app),
               value.contains(token) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let lastValue = readerRenderedContentStateValue(in: app) ?? "nil"
        XCTFail(
            "Expected reader rendered-content state to contain '\(token)' within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /// Reads the compact reader state export without walking drawer or overflow menu contents.
    func readerRenderedContentStateValue(in app: XCUIApplication) -> String? {
        if let headerValue = readerDocumentHeaderStateValue(in: app) {
            return headerValue
        }
        for stateElement in readerRenderedContentStateElements(in: app) {
            if let value = snapshotStateString(from: stateElement, containing: "windowOrder=") {
                return value
            }
        }
        return nil
    }

    /// Reads reader state from the early document-header chrome before probing rendered content.
    func readerDocumentHeaderStateValue(in app: XCUIApplication) -> String? {
        let headerCandidates = [
            app.otherElements["readerDocumentHeader"].firstMatch,
            app.staticTexts["readerDocumentHeader"].firstMatch,
        ]
        for header in headerCandidates {
            if let value = snapshotStateString(from: header, containing: "windowOrder=") {
                return value
            }
        }
        return nil
    }

    /**
     Reads an element's exported accessibility value or label without recording a snapshot failure.

     The XCUITest convenience accessors `value` and `label` re-resolve their query and record a hard
     "Failed to get matching snapshot" test failure when the element disappears between an earlier
     `exists` check and the property read. Reader chrome (the document header and the compact state
     export) is recreated during navigation transitions, so this optional probe instead takes a
     single throwing `snapshot()` and tolerates absence via `try?`, returning `nil` rather than
     failing the test when the element is mid-teardown.

     - Parameters:
       - element: Reader-state export element whose value or label should be read defensively.
       - marker: Substring that must be present for the read to count as a valid reader-state export.
     - Returns: The matching value or label string, or `nil` when the element cannot be snapshotted
       or does not contain the marker.
     - Side effects: none.
     - Failure modes: never records an XCTest failure; absence resolves to `nil`.
     */
    private func snapshotStateString(
        from element: XCUIElement,
        containing marker: String
    ) -> String? {
        guard let snapshot = try? element.snapshot() else {
            return nil
        }
        if let value = snapshot.value as? String, value.contains(marker) {
            return value
        }
        if snapshot.label.contains(marker) {
            return snapshot.label
        }
        return nil
    }

    /// Returns compact reader state export queries without probing broad element sets.
    func readerRenderedContentStateElements(in app: XCUIApplication) -> [XCUIElement] {
        [
            app.staticTexts["readerRenderedContentState"].firstMatch,
            app.textFields["readerRenderedContentState"].firstMatch,
        ]
    }

    /// Returns whether the compact reader state export currently contains one token.
    func readerRenderedContentStateContains(_ token: String, in app: XCUIApplication) -> Bool {
        readerRenderedContentStateValue(in: app)?.contains(token) == true
    }

    /// Polls the compact reader state export for one token without recording a failure.
    func waitForReaderRenderedContentStateIfPresent(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if readerRenderedContentStateContains(token, in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return readerRenderedContentStateContains(token, in: app)
    }

    /// Reads a boolean key from the compact reader state export.
    func readerRenderedContentStateFlag(_ key: String, in app: XCUIApplication) -> Bool? {
        guard let stateValue = readerRenderedContentStateValue(in: app) else {
            return nil
        }
        if stateValue.contains("\(key)=true") {
            return true
        }
        if stateValue.contains("\(key)=false") {
            return false
        }
        return nil
    }

    /**
     Waits for the reader shell's stable navigation chrome to become interactive again.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before returning `false`.
     * - Returns: `true` when the reader's compact state export reports that transient reader
     *   surfaces and pushed reader destinations are closed, and My Notes is no longer fronting the
     *   primary reader chrome.
     * - Side effects:
     *   - polls the compact reader state export while modal surfaces dismiss back to the reader
     *     shell, avoiding full-toolbar snapshots while WebView content is settling
     * - Failure modes:
     *   - returns `false` when the reader shell never restores its primary controls before timeout
     */
    func waitForReaderShellReady(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let readerState = readerRenderedContentStateValue(in: app)
            let readerSurfacesClosed = readerState.map { state in
                let drawerClosed = state.contains("drawerVisible=false") || !state.contains("drawerVisible=")
                let overflowClosed = state.contains("overflowVisible=false") || !state.contains("overflowVisible=")
                let sheetClosed = state.contains("readerSheet=none") || !state.contains("readerSheet=")
                let destinationClosed = state.contains("readerDestination=none") ||
                    !state.contains("readerDestination=")
                let searchClosed = state.contains("searchVisible=false") || !state.contains("searchVisible=")
                let myNotesClosed = state.contains("myNotesVisible=false") || !state.contains("myNotesVisible=")
                return drawerClosed &&
                    overflowClosed &&
                    sheetClosed &&
                    destinationClosed &&
                    searchClosed &&
                    myNotesClosed
            } ?? false

            if readerState != nil,
               readerSurfacesClosed {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Waits for the primary reader reference control to change away from one previous value.
     *
     * - Parameters:
     *   - initialValue: Previously observed reader reference that should no longer be visible.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first non-empty reader reference value different from `initialValue`.
     * - Side effects:
     *   - polls the live reader toolbar until `bookChooserButton` exports a different value
     * - Failure modes:
     *   - records an XCTest failure if the reader reference never changes before the timeout
     */
    func waitForReaderReferenceValueToChange(
        from initialValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let referenceButton = requireButton(
            "bookChooserButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = referenceButton.value as? String,
               !value.isEmpty,
               value != initialValue {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallbackValue = referenceButton.value as? String ?? ""
        XCTAssertNotEqual(
            fallbackValue,
            initialValue,
            "Expected bookChooserButton to change away from '\(initialValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallbackValue
    }

    /**
     Taps one bottom window-tab pill by order number and waits for its active state to surface.
     */
    func tapWindowTab(
        _ order: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = "windowTabButton::\(order)"
        let tabButton = requireElement(identifier, in: app, timeout: timeout, file: file, line: line)
        tapElementReliably(tabButton, timeout: timeout, file: file, line: line)

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = tabButton.value as? String,
               value.contains("state=active") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let lastValue = tabButton.value.map { "\($0)" } ?? "nil"
        XCTFail(
            "Expected window tab \(order) to become active within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Adds one reader window and waits until the newly created tab is active and rendering.
     *
     * - Parameters:
     *   - order: Order number expected on the new window tab.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the real add-window control in the reader tab bar
     *   - waits for the new tab pill to appear, become active, and export the matching
     *     `readerRenderedContentState` window order before returning
     *   - retries the add tap once when the expected new tab never materializes
     * - Failure modes:
     *   - fails if the add control or the expected tab does not appear
     *   - fails if the new tab appears but never becomes the active rendered window
     */
    func addWindowTab(
        expectingOrder order: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = "windowTabButton::\(order)"
        var sawExpectedTab = false
        var lastTabValue = "nil"
        var lastRenderedState = "nil"

        for attempt in 1...2 {
            tapElementReliably(
                requireElement("windowTabAddButton", in: app, timeout: timeout, file: file, line: line),
                timeout: timeout,
                file: file,
                line: line
            )

            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let tabButton = resolvedElement(identifier, in: app) {
                    sawExpectedTab = true
                    lastTabValue = tabButton.value.map { "\($0)" } ?? "nil"
                    lastRenderedState = readerRenderedContentStateValue(in: app) ?? "nil"
                    if lastTabValue.contains("state=active") && lastRenderedState.contains("windowOrder=\(order)") {
                        return
                    }
                } else {
                    lastRenderedState = readerRenderedContentStateValue(in: app) ?? "nil"
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline

            if sawExpectedTab || attempt == 2 {
                break
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail(
            "Expected added window tab \(order) to become the active rendered window within \(timeout) seconds; last tab value was '\(lastTabValue)' and last reader state was '\(lastRenderedState)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified button element to exist.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected on a button element.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved button element.
     * - Side effects:
     *   - queries the live button hierarchy repeatedly until the identifier resolves or the
     *     timeout expires
     * - Failure modes:
     *   - records an XCTest failure if the requested button never appears within the allotted
     *     timeout
     */
}
