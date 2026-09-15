import Foundation
import Darwin
import XCTest
import Vision
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies reader administration actions and Settings route Android shortcut rows.
     *
     * Package tests own the full Application Preferences row catalog. This UI smoke keeps the live
     * route contract: AI Settings remains reachable from the Android reader drawer and reproduces
     * Android's setup-to-connection hierarchy and explicit disclaimer gate;
     * Application Preferences opens the same AI screen; and Global text options opens root-scoped
     * Text Display settings.
     *
     * - Side effects:
     *   - launches the app with deterministic in-memory persistence
     *   - opens AI Settings directly from the reader drawer and pushes Connection settings
     *   - verifies Android's zero-provider row visibility and cancels both protected entry points
     *   - explicitly accepts once, then verifies Quick Setup resumes at provider selection
     *   - verifies persisted acceptance bypasses the gate for Quick Setup and Add Provider
     *   - pushes Settings from the reader action surface
     *   - opens the shared AI Settings destination from Application Preferences
     *   - activates the production Global text options row
     * - Failure modes:
     *   - fails if AI Settings skips Android's centered setup or separate Connection settings screen
     *   - fails if zero-provider Connection settings exposes configured-only rows
     *   - fails if cancellation counts as disclaimer acceptance
     *   - fails if explicit acceptance does not resume and persist for the protected action
     *   - fails if disclaimer copy renders localization identifiers instead of Android's text
     *   - fails if Settings still presents as a sheet instead of a reader destination
     *   - fails if AI Settings or Global text options cannot be activated from visible Settings UI
     *   - fails if Global text options opens any scope other than `global`
     */
    func testSettingsApplicationShortcutsOpenGlobalTextOptions() {
        let app = makeApp()
        app.launch()

        tapReaderAction("readerOpenAISettingsAction", in: app, timeout: 20)
        XCTAssertTrue(requireElement("aiSettingsTopAppBarBackButton", in: app, timeout: 20).exists)
        waitForReaderRenderedContentState(containing: "readerDestination=aiSettings", in: app, timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Configure AI"].waitForExistence(timeout: 10),
            "Expected Android's centered Configure AI state before any provider exists."
        )
        XCTAssertTrue(requireElement("aiConfigureConnectionButton", in: app, timeout: 10).exists)
        XCTAssertFalse(unresolvedElement("aiQuickSetupButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("aiAddProviderLink", in: app).exists)

        tapElementReliably(requireElement("aiConfigureConnectionButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiQuickSetupButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiProvidersLink", in: app, timeout: 10).exists)
        XCTAssertFalse(
            unresolvedElement("aiModelsLink", in: app).exists,
            "Android hides Models, Behavior, Advanced, and Usage until a provider exists."
        )

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiDisclaimerAcceptButton", in: app, timeout: 10).exists)
        let localizedDisclaimerPoint = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI can make mistakes")
        ).firstMatch
        XCTAssertTrue(
            localizedDisclaimerPoint.waitForExistence(timeout: 10),
            "Expected Android's localized disclaimer point instead of a raw resource key."
        )
        XCTAssertFalse(app.staticTexts["ai_disclaimer_point1"].exists)
        XCTAssertFalse(
            unresolvedElement("aiQuickSetupButton", in: app).isHittable,
            "Android's modal disclaimer must block the underlying Quick Setup row."
        )
        XCTAssertFalse(
            requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).isHittable,
            "Android's modal disclaimer must block the underlying app-owned action bar."
        )
        tapAppOwnedDialogAction(
            "aiDisclaimerCancelButton",
            dialogIdentifier: "aiDisclaimerScreen",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiProvidersLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Add Provider must use Android's same explicit disclaimer gate."
        )
        tapAppOwnedDialogAction(
            "aiDisclaimerCancelButton",
            dialogIdentifier: "aiDisclaimerScreen",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Cancelling the disclaimer must not count as acceptance."
        )
        let disclaimerScrollView = app.scrollViews["aiDisclaimerScrollView"].firstMatch
        XCTAssertTrue(
            disclaimerScrollView.waitForExistence(timeout: 10),
            "Expected the app-owned disclaimer's visible scroll container."
        )
        let disclaimerAcceptButton = requireElement("aiDisclaimerAcceptButton", in: app, timeout: 10)
        for _ in 0..<8 where !disclaimerAcceptButton.isHittable {
            disclaimerScrollView.swipeUp()
        }
        XCTAssertTrue(
            disclaimerAcceptButton.isHittable,
            "Expected the full Android disclaimer to scroll to its explicit acceptance action."
        )
        tapElementReliably(disclaimerAcceptButton, timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10).exists,
            "Explicit acceptance must resume Android's Quick Setup provider chooser."
        )
        tapElementReliably(requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiQuickSetupCredentialScreen", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiQuickSetupSaveButton", in: app, timeout: 10).exists)
        tapAppOwnedDialogAction(
            "aiQuickSetupCancelButton",
            dialogIdentifier: "aiQuickSetupCredentialScreen",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10).exists,
            "Persisted acceptance must bypass the disclaimer on later protected actions."
        )
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapAppOwnedDialogAction(
            "aiQuickSetupCancelButton",
            dialogIdentifier: "aiQuickSetupProviderList",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiProvidersLink", in: app, timeout: 10), timeout: 10)
        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProviderTypeSelectionScreen", in: app, timeout: 10).exists)
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapElementReliably(requireElement("aiProviderType_GEMINI", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiProviderSaveButton", in: app, timeout: 10).exists,
            "Persisted acceptance must resume Add Provider without another disclaimer."
        )
        tapAppOwnedDialogAction(
            "aiProviderCancelButton",
            dialogIdentifier: "aiProviderEditorScreen",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        let aiSettingsBackButton = requireElement("aiSettingsTopAppBarBackButton", in: app, timeout: 10)
        tapElementReliably(aiSettingsBackButton, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected AI Settings back navigation to return to the reader shell."
        )

        openSettings(in: app)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)

        tapSettingsElement("settingsAISettingsLink", in: app, timeout: 20)
        let nestedAISettingsBackButton = requireElement(
            "aiSettingsTopAppBarBackButton",
            in: app,
            timeout: 20
        )
        tapElementReliably(nestedAISettingsBackButton, timeout: 10)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)

        tapSettingsElement("settingsGlobalTextOptionsLink", in: app, timeout: 20)
        XCTAssertTrue(requireElement("textDisplaySettingsScreen", in: app, timeout: 20).exists)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=global", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("textDisplayOpenGlobalSettingsButton", in: app).exists)
    }

    /**
     Verifies iOS omits unsupported volume controls and keeps workspace color workspace-owned.

     Android exposes `Volume buttons scroll` because its reader consumes physical volume keys;
     iOS has no equivalent consumer, so the visible Settings search must return no row. Accepted
     ADR 0005 keeps `workspace_color` out of true global and window color routes and exposes it from
     reader workspace Text Options, where the durable Workspace owns the value.

     - Side effects:
       - launches the baseline reader and opens Application Preferences
       - searches for Android's unsupported volume-button row and observes an empty result
       - proves Global Colors omits the workspace-owned row
       - opens reader workspace Colors, cancels one staged edit, commits another, and reopens the
         same workspace route to observe the persisted RGB
     - Failure modes:
       - fails if the unsupported volume-button setting appears in visible Settings search
       - fails if global scope exposes workspace-owned metadata or workspace scope omits it
       - fails if color Cancel mutates, color OK does not commit, or reader navigation loses the
         active Workspace owner
     */
    func testSettingsSearchHidesVolumeButtonsAndWorkspaceColorsCommitOwnedValue() {
        let app = makeApp()
        app.launch()
        openSettings(in: app)
        let settingsForm = requireObservedSettingsElement(
            app.otherElements["settingsForm"].firstMatch,
            identifier: "settingsForm",
            timeout: 10
        )

        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["settingsSearchButton"].firstMatch,
                identifier: "settingsSearchButton",
                timeout: 10
            ),
            timeout: 10
        )
        let settingsSearchField = requireObservedSettingsElement(
            app.textFields["settingsSearchField"].firstMatch,
            identifier: "settingsSearchField",
            timeout: 10
        )
        replaceText(
            in: settingsSearchField,
            with: "Volume buttons scroll",
            placeholderHints: ["Search"]
        )
        XCTAssertTrue(
            app.staticTexts["No settings found"].waitForExistence(timeout: 10),
            "A Settings search for Android's hardware-volume behavior must have no iOS result."
        )
        XCTAssertFalse(
            app.switches["settingsSwitch::volume_keys_scroll"].firstMatch.exists,
            "iOS must not expose Android's volume-button setting without a hardware-key consumer."
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["settingsSearchClearButton"].firstMatch,
                identifier: "settingsSearchClearButton",
                timeout: 10
            ),
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["settingsSearchButton"].firstMatch,
                identifier: "settingsSearchButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(settingsForm.exists)

        tapSettingsElement("settingsGlobalTextOptionsLink", in: app, timeout: 20)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=global",
            timeout: 10,
            predicate: { $0.contains("scope=global") }
        )
        XCTAssertFalse(app.buttons["textDisplayOpenWorkspaceSettingsButton"].firstMatch.exists)
        XCTAssertFalse(app.buttons["textDisplayOpenGlobalSettingsButton"].firstMatch.exists)
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.otherElements["colorSettingsScreen"].firstMatch,
                identifier: "colorSettingsScreen",
                timeout: 10
            ).exists
        )
        XCTAssertFalse(
            app.buttons["colorSettingsWorkspaceColorPicker"].firstMatch.exists,
            "Accepted ADR 0005 keeps workspace-owned color metadata out of true Global Colors."
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["colorSettingsTopAppBarBackButton"].firstMatch,
                identifier: "colorSettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=global",
            timeout: 10,
            predicate: { $0.contains("scope=global") }
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.otherElements["settingsForm"].firstMatch,
                identifier: "settingsForm",
                timeout: 10
            ).exists
        )
        dismissSettings(in: app)

        _ = openAllTextOptions(in: app)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=workspace",
            timeout: 10,
            predicate: { $0.contains("scope=workspace") }
        )
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10),
            timeout: 10
        )
        let workspaceColorRow = requireObservedSettingsElement(
            app.buttons["colorSettingsWorkspaceColorPicker"].firstMatch,
            identifier: "colorSettingsWorkspaceColorPicker",
            timeout: 10
        )
        tapElementReliably(workspaceColorRow, timeout: 10)
        let initialColorDialog = app.otherElements["androidColorPickerDialog"].firstMatch
        XCTAssertTrue(initialColorDialog.waitForExistence(timeout: 10))
        let initialHexField = app.textFields["androidColorPickerHexField"].firstMatch
        XCTAssertTrue(initialHexField.waitForExistence(timeout: 10))
        let initialHex = currentTextEntryValue(in: initialHexField, placeholderHints: ["RRGGBB"])
        guard initialHex.count == 6 else {
            XCTFail("Expected the workspace-color dialog to expose six RGB digits; value='\(initialHex)'.")
            return
        }
        let changedHex = initialHex.caseInsensitiveCompare("13579B") == .orderedSame ? "2468AC" : "13579B"
        replaceText(in: initialHexField, with: changedHex, placeholderHints: ["RRGGBB"])
        app.typeText(XCUIKeyboardKey.return.rawValue)
        tapAppOwnedDialogAction(
            "androidColorPickerCancelButton",
            dialogIdentifier: "androidColorPickerDialog",
            dialogElement: initialColorDialog,
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )

        tapElementReliably(workspaceColorRow, timeout: 10)
        let canceledColorDialog = app.otherElements["androidColorPickerDialog"].firstMatch
        XCTAssertTrue(canceledColorDialog.waitForExistence(timeout: 10))
        let canceledHexField = app.textFields["androidColorPickerHexField"].firstMatch
        XCTAssertTrue(canceledHexField.waitForExistence(timeout: 10))
        XCTAssertEqual(
            currentTextEntryValue(in: canceledHexField, placeholderHints: ["RRGGBB"]).uppercased(),
            initialHex.uppercased(),
            "Cancel must discard the staged workspace color."
        )
        replaceText(in: canceledHexField, with: changedHex, placeholderHints: ["RRGGBB"])
        app.typeText(XCUIKeyboardKey.return.rawValue)
        tapAppOwnedDialogAction(
            "androidColorPickerConfirmButton",
            dialogIdentifier: "androidColorPickerDialog",
            dialogElement: canceledColorDialog,
            expectedTitle: "OK",
            in: app,
            timeout: 10
        )

        tapElementReliably(workspaceColorRow, timeout: 10)
        let committedColorDialog = app.otherElements["androidColorPickerDialog"].firstMatch
        XCTAssertTrue(committedColorDialog.waitForExistence(timeout: 10))
        let committedHexField = app.textFields["androidColorPickerHexField"].firstMatch
        XCTAssertTrue(committedHexField.waitForExistence(timeout: 10))
        XCTAssertEqual(
            currentTextEntryValue(in: committedHexField, placeholderHints: ["RRGGBB"]).uppercased(),
            changedHex,
            "OK must commit the active workspace color."
        )
        tapAppOwnedDialogAction(
            "androidColorPickerCancelButton",
            dialogIdentifier: "androidColorPickerDialog",
            dialogElement: committedColorDialog,
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["colorSettingsTopAppBarBackButton"].firstMatch,
                identifier: "colorSettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 20))

        _ = openAllTextOptions(in: app)
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10),
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["colorSettingsWorkspaceColorPicker"].firstMatch,
                identifier: "colorSettingsWorkspaceColorPicker",
                timeout: 10
            ),
            timeout: 10
        )
        let reopenedColorDialog = app.otherElements["androidColorPickerDialog"].firstMatch
        XCTAssertTrue(reopenedColorDialog.waitForExistence(timeout: 10))
        let reopenedHexField = app.textFields["androidColorPickerHexField"].firstMatch
        XCTAssertTrue(reopenedHexField.waitForExistence(timeout: 10))
        XCTAssertEqual(
            currentTextEntryValue(in: reopenedHexField, placeholderHints: ["RRGGBB"]).uppercased(),
            changedHex,
            "Reopening workspace Colors must observe the durable workspace-owned RGB."
        )
        tapAppOwnedDialogAction(
            "androidColorPickerCancelButton",
            dialogIdentifier: "androidColorPickerDialog",
            dialogElement: reopenedColorDialog,
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies one real Android `ListPreference` row uses the app-owned single-choice interaction.

     The package catalog test owns the complete list of menu-backed preferences. This UI route
     proves the toolbar-action row remains compact until tapped, exposes exactly one selected value
     in Android order, commits an alternate option immediately, and preserves it through reopen and
     Cancel. Those visible outcomes replace the removed private `SettingsView` source-spelling ban.
     */
    func testSettingsListPreferenceUsesSingleChoiceDialogAndPersistsSelection() {
        let app = makeApp()
        app.launch()
        openSettings(in: app)

        let rowID = "settingsListPreferenceMenu::toolbar_button_actions"
        let dialogID = "\(rowID)Dialog"
        let options = [
            (
                id: "\(dialogID)Choice::default",
                title: "Press to open menu, long press for documents screen (default)"
            ),
            (
                id: "\(dialogID)Choice::swap-menu",
                title: "Press to open next document, long press to open menu"
            ),
            (
                id: "\(dialogID)Choice::swap-activity",
                title: "Press to open next document, long press for documents screen"
            ),
        ]

        let row = requireSettingsNavigationControl(rowID, in: app, timeout: 20)
        XCTAssertEqual(row.elementType, .button)
        XCTAssertFalse(app.otherElements[dialogID].firstMatch.exists)
        XCTAssertTrue(
            options.allSatisfy { !app.buttons[$0.id].firstMatch.exists },
            "ListPreference options must not occupy inline Settings rows before the action."
        )

        tapSettingsElement(rowID, in: app, timeout: 20)
        let dialog = app.otherElements[dialogID].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        let dialogChoiceButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "\(dialogID)Choice::")
        )
        XCTAssertEqual(
            dialogChoiceButtons.allElementsBoundByIndex.map(\.identifier),
            options.map { $0.id },
            "The dialog marker and its Android radio rows are accessibility siblings; the global button inventory must retain Android order."
        )

        let initialChoices = options.map { app.buttons[$0.id].firstMatch }
        XCTAssertTrue(initialChoices.allSatisfy { $0.waitForExistence(timeout: 10) })
        let initiallySelected = initialChoices.indices.filter {
            initialChoices[$0].value as? String == "Selected"
        }
        guard initiallySelected.count == 1, let initialIndex = initiallySelected.first else {
            XCTFail("Expected exactly one selected Android list-preference option.")
            return
        }
        let alternateIndex = initialIndex == 0 ? 1 : 0
        tapElementReliably(initialChoices[alternateIndex], timeout: 10)
        XCTAssertTrue(
            waitForUITestCondition("single-choice dialog dismisses after selection", timeout: 10) {
                !dialog.exists
            }
        )

        let committedRow = requireSettingsNavigationControl(rowID, in: app, timeout: 10)
        XCTAssertEqual(committedRow.value as? String, options[alternateIndex].title)
        tapSettingsElement(rowID, in: app, timeout: 10)
        let reopenedDialog = app.otherElements[dialogID].firstMatch
        XCTAssertTrue(reopenedDialog.waitForExistence(timeout: 10))
        XCTAssertEqual(
            dialogChoiceButtons.allElementsBoundByIndex.map(\.identifier),
            options.map { $0.id },
            "Reopening must restore the same complete Android-order radio inventory."
        )
        let reopenedChoices = options.map { app.buttons[$0.id].firstMatch }
        XCTAssertTrue(reopenedChoices.allSatisfy { $0.waitForExistence(timeout: 10) })
        let reopenedSelected = reopenedChoices.indices.filter {
            reopenedChoices[$0].value as? String == "Selected"
        }
        XCTAssertEqual(
            reopenedSelected,
            [alternateIndex],
            "Reopening must publish exactly one selected radio row for the committed value."
        )
        tapAppOwnedDialogAction(
            "\(dialogID)CancelButton",
            dialogIdentifier: dialogID,
            dialogElement: reopenedDialog,
            in: app,
            timeout: 10
        )
        XCTAssertTrue(
            waitForUITestCondition("single-choice Cancel returns to Settings", timeout: 10) {
                !reopenedDialog.exists && committedRow.exists
            }
        )
        XCTAssertEqual(
            requireSettingsNavigationControl(rowID, in: app, timeout: 10).value as? String,
            options[alternateIndex].title
        )
    }

    /**
     Verifies Android's reader All Text Options route, color reset, workspace parent link, and
     font-family editor interaction.
     *
     Package tests own text-display row order, row visibility, editor state semantics, and Android
     value normalization. This UI smoke keeps the production route live: the reader action opens
     workspace-scoped Text Display settings, the workspace scope exposes only the global parent
     link, and the font-family editor exposes app-owned Android radio/actions behavior with
     cancel-and-return semantics.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - opens the real overflow menu action identified by Android's All Text Options row
     *   - opens Colors from that workspace-scoped route and resets seeded custom colors
     *   - taps the Global text options parent link inside Text Display settings
     *   - opens the font-family editor, stages an alternate option, and cancels it
     *   - reopens the editor to verify the original option and returns to the reader
     * - Failure modes:
     *   - fails if the overflow action is routed to global Application Preferences
     *   - fails if the overflow action is routed to window-scoped Text Display settings
     *   - fails if the Colors route or reset action is missing from the visible Android path
     *   - fails if the workspace parent link is missing or if global scope still exposes parent
     *     links
     *   - fails if the editor omits Android's radio/action controls or Cancel commits its draft
     *   - fails if the app-owned Back stack cannot return through workspace scope to the reader
     */
    func testAllTextOptionsWorkspaceRouteAndFontEditor() {
        let app = makeApp()
        app.launch()

        let textDisplayScreen = openAllTextOptions(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=textOptions", in: app, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=workspace",
            timeout: 10,
            predicate: { $0.contains("scope=workspace") }
        )
        XCTAssertFalse(
            app.otherElements["settingsForm"].firstMatch.exists,
            "Expected All Text Options to open the Text Display destination, not Application Preferences."
        )

        XCTAssertFalse(
            app.buttons["textDisplayOpenWorkspaceSettingsButton"].firstMatch.exists,
            "Workspace text options must not show Android's window-only workspace parent link."
        )

        let colorsLink = requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10)
        tapElementReliably(colorsLink, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["colorSettingsScreen"].firstMatch,
            identifier: "colorSettingsScreen",
            expectedDescription: "colorCustom",
            timeout: 10,
            predicate: { $0 == "colorCustom" }
        )
        XCTAssertEqual(app.otherElements["colorSettingsScreen"].firstMatch.value as? String, "colorCustom")

        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["colorSettingsResetButton"].firstMatch,
                identifier: "colorSettingsResetButton",
                timeout: 10
            ),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "colorSettingsResetDialogAction::yes",
            dialogIdentifier: "colorSettingsResetDialog",
            expectedTitle: "Yes",
            in: app,
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["colorSettingsScreen"].firstMatch,
            identifier: "colorSettingsScreen",
            expectedDescription: "colorDefaults",
            timeout: 10,
            predicate: { $0 == "colorDefaults" }
        )

        let colorSettingsBackButton = requireObservedSettingsElement(
            app.buttons["colorSettingsTopAppBarBackButton"].firstMatch,
            identifier: "colorSettingsTopAppBarBackButton",
            timeout: 10
        )
        tapElementReliably(colorSettingsBackButton, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=workspace",
            timeout: 10,
            predicate: { $0.contains("scope=workspace") }
        )

        let globalLink = requireReachableTextDisplayButton(
            "textDisplayOpenGlobalSettingsButton",
            in: app,
            revealDirection: .upper,
            timeout: 10
        )
        tapElementReliably(globalLink, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=global",
            timeout: 10,
            predicate: { $0.contains("scope=global") }
        )
        XCTAssertFalse(app.buttons["textDisplayOpenWorkspaceSettingsButton"].firstMatch.exists)
        XCTAssertFalse(app.buttons["textDisplayOpenGlobalSettingsButton"].firstMatch.exists)

        let fontFamilyButton = requireReachableTextDisplayButton("textDisplayFontFamilyButton", in: app, timeout: 10)
        tapElementReliably(fontFamilyButton, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "preferenceEditor=fontFamily",
            timeout: 10,
            predicate: { $0.contains("preferenceEditor=fontFamily") }
        )
        XCTAssertTrue(
            app.otherElements["textDisplayPreferenceEditorOverlay"].waitForExistence(timeout: 10),
            "Expected the Android-style text display editor overlay to be visible."
        )
        XCTAssertTrue(
            app.scrollViews["textDisplayFontFamilyOptionList"].firstMatch.waitForExistence(timeout: 10),
            "Expected the font-family choices in the rendered editor scroll view."
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayPreferenceEditorResetButton"].firstMatch,
                identifier: "textDisplayPreferenceEditorResetButton",
                timeout: 10
            ).exists
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayPreferenceEditorOKButton"].firstMatch,
                identifier: "textDisplayPreferenceEditorOKButton",
                timeout: 10
            ).exists
        )
        let alternateFontOption = requireObservedSettingsElement(
            app.buttons["textDisplayFontFamilyOption::0"].firstMatch,
            identifier: "textDisplayFontFamilyOption::0",
            timeout: 10
        )
        let originalFontOption = requireObservedSettingsElement(
            app.buttons["textDisplayFontFamilyOption::2"].firstMatch,
            identifier: "textDisplayFontFamilyOption::2",
            timeout: 10
        )
        XCTAssertEqual(originalFontOption.value as? String, "selected")
        XCTAssertEqual(alternateFontOption.value as? String, "unselected")
        tapElementReliably(alternateFontOption, timeout: 10)
        waitForObservedSettingsValue(
            alternateFontOption,
            identifier: alternateFontOption.identifier,
            expectedDescription: "selected",
            timeout: 10,
            predicate: { $0 == "selected" }
        )
        tapAppOwnedDialogAction(
            "textDisplayPreferenceEditorCancelButton",
            dialogIdentifier: "textDisplayPreferenceEditorDialog",
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=global",
            timeout: 10,
            predicate: { $0.contains("scope=global") }
        )

        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayFontFamilyButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertEqual(
            requireObservedSettingsElement(
                app.buttons["textDisplayFontFamilyOption::2"].firstMatch,
                identifier: "textDisplayFontFamilyOption::2",
                timeout: 10
            ).value as? String,
            "selected",
            "Cancel must preserve the previously committed font family."
        )
        XCTAssertEqual(
            requireObservedSettingsElement(
                app.buttons["textDisplayFontFamilyOption::0"].firstMatch,
                identifier: "textDisplayFontFamilyOption::0",
                timeout: 10
            ).value as? String,
            "unselected",
            "Reopening must expose one selected value instead of retaining the canceled draft."
        )
        tapAppOwnedDialogAction(
            "textDisplayPreferenceEditorCancelButton",
            dialogIdentifier: "textDisplayPreferenceEditorDialog",
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=workspace",
            timeout: 10,
            predicate: { $0.contains("scope=workspace") }
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected the app-owned Text Options Back stack to return to the reader."
        )
    }

    /**
    Verifies Android's per-window Text Options route, parent-link back stack, and pane Close action.

    Android's pane/window menu owns both per-window Text Options and Close. These are distinct
    commands, but both require the same setup: create a second reader pane, open that pane's
    hamburger menu, and exercise a pane-scoped command. Android's single-top
    `TextDisplaySettingsActivity` pushes each parent scope onto its internal bundle stack, so Back
    from workspace scope must first restore window scope before a second Back returns to the reader.
    Keeping both commands in one workflow removes a duplicate cold launch while preserving that
    visible scope ladder and the pane-delete transaction.
     *
     * - Side effects:
     *   - launches the app, creates a second reader window through the tab bar, and opens the
     *     active pane hamburger menu
     *   - activates the pane-level All text options command
     *   - opens window Colors and verifies the workspace-owned row is absent
     *   - taps the workspace parent link from the window-scoped Text Display screen
     *   - navigates Back through window scope to the reader, reopens the same pane menu, and
     *     activates Close
     * - Failure modes:
     *   - fails if pane All text options routes to workspace/global scope
     *   - fails if window scope lacks either Android parent link
     *   - fails if window Colors exposes the workspace-owned color row
     *   - fails if the workspace parent link does not navigate to `scope=workspace`
     *   - fails if Back skips or cannot restore the preceding `scope=window` activity
     *   - fails if pane-menu Close terminates the app, leaves the deleted tab visible, or removes
     *     the remaining pane menu/add-window affordances
     */
    func testPaneAllTextOptionsOpensWindowScopeAndWorkspaceParentLink() {
        let app = makeApp()
        app.launch()

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        let paneMenu = requireObservedSettingsElement(
            app.buttons["windowPaneMenuButton::1"].firstMatch,
            identifier: "windowPaneMenuButton::1",
            timeout: 10
        )
        openPaneMenu(paneMenu, in: app, timeout: 10)
        let allTextOptionsAction = requirePaneMenuItem("windowPaneMenuItem::allTextOptions", in: app, timeout: 10)
        tapElementReliably(allTextOptionsAction, timeout: 10)

        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=window",
            timeout: 10,
            predicate: { $0.contains("scope=window") }
        )
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.otherElements["colorSettingsScreen"].firstMatch,
                identifier: "colorSettingsScreen",
                timeout: 10
            ).exists
        )
        XCTAssertFalse(
            app.buttons["colorSettingsWorkspaceColorPicker"].firstMatch.exists,
            "Accepted ADR 0005 keeps workspace-owned color metadata out of window Colors."
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["colorSettingsTopAppBarBackButton"].firstMatch,
                identifier: "colorSettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=window",
            timeout: 10,
            predicate: { $0.contains("scope=window") }
        )
        let workspaceLink = requireReachableTextDisplayButton(
            "textDisplayOpenWorkspaceSettingsButton",
            in: app,
            revealDirection: .upper,
            timeout: 10
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayOpenGlobalSettingsButton"].firstMatch,
                identifier: "textDisplayOpenGlobalSettingsButton",
                timeout: 10
            ).exists
        )

        tapElementReliably(workspaceLink, timeout: 10)
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=workspace",
            timeout: 10,
            predicate: { $0.contains("scope=workspace") }
        )
        XCTAssertFalse(app.buttons["textDisplayOpenWorkspaceSettingsButton"].firstMatch.exists)
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayOpenGlobalSettingsButton"].firstMatch,
                identifier: "textDisplayOpenGlobalSettingsButton",
                timeout: 10
            ).exists
        )

        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        waitForObservedSettingsValue(
            app.otherElements["textDisplaySettingsScreen"].firstMatch,
            identifier: "textDisplaySettingsScreen",
            expectedDescription: "scope=window",
            timeout: 10,
            predicate: { $0.contains("scope=window") }
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayOpenWorkspaceSettingsButton"].firstMatch,
                identifier: "textDisplayOpenWorkspaceSettingsButton",
                timeout: 10
            ).exists
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["textDisplayOpenGlobalSettingsButton"].firstMatch,
                identifier: "textDisplayOpenGlobalSettingsButton",
                timeout: 10
            ).exists
        )

        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected app-owned Text Options back navigation to return to the reader shell before closing the pane."
        )
        openPaneMenu(
            requireObservedSettingsElement(
                app.buttons["windowPaneMenuButton::1"].firstMatch,
                identifier: "windowPaneMenuButton::1",
                timeout: 10
            ),
            in: app,
            timeout: 10
        )
        tapElementReliably(
            requirePaneMenuItem("windowPaneMenuItem::close", in: app, timeout: 12),
            timeout: 10
        )

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected reader shell to remain alive after pane-menu Close."
        )
        waitForClosedWindowOrder(1, in: app, timeout: 15)
        let finalState = readerRenderedContentStateValue(in: app) ?? "nil"
        XCTAssertFalse(finalState.contains("windowOrder=none"), "Expected an active reader window after Close; state=\(finalState)")
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["windowPaneMenuButton::0"].firstMatch,
                identifier: "windowPaneMenuButton::0",
                timeout: 10
            ).exists
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.buttons["windowTabAddButton"].firstMatch,
                identifier: "windowTabAddButton",
                timeout: 10
            ).exists
        )
    }

    /**
     Waits until the reader's live footer model no longer contains a closed window order.

     The tab bar is backed by `WindowManager.allWindows`, which the compact reader state exposes as
     `windowTabOrders`. Watching that model keeps the assertion tied to the close transaction itself
     instead of a stale accessibility snapshot from the removed SwiftUI button.
     *
     * - Parameters:
     *   - order: Window order that should be removed from the footer model.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for SwiftData deletion and SwiftUI reconciliation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: polls the compact reader state export.
     * - Failure modes: records an XCTest failure when the closed order remains present or the
     *   reader loses its active-window state.
     */
    private func waitForClosedWindowOrder(
        _ order: Int,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastOrders = windowTabOrdersFromReaderState(in: app)
        waitForResolvedSemanticState(
            named: "readerClosedWindowOrder",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) ?? "nil" },
            success: { state in
                if let rawOrders = self.readerRenderedContentStateToken("windowTabOrders", in: state) {
                    lastOrders = rawOrders == "none"
                        ? []
                        : rawOrders
                            .split(separator: ",")
                            .compactMap { Int($0) }
                } else {
                    lastOrders = nil
                }
                guard let lastOrders else {
                    return false
                }
                return !lastOrders.contains(order) && !state.contains("windowOrder=none")
            },
            failureDescription: { state in
                """
                Expected window order \(order) to be removed within \(timeout) seconds; \
                orders=\(String(describing: lastOrders)), state=\(state)
                """
            },
            file: file,
            line: line
        )
    }

    /**
     Opens the Android-style pane popup menu and waits until its custom SwiftUI surface is visible.

     This helper performs one tap on the production pane hamburger and then passively waits for the
     actual popup container. A dropped interaction remains a test failure.
     *
     * - Parameters:
     *   - paneMenu: The pane hamburger button already resolved by accessibility identifier.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the button and popup handshake.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: taps the pane hamburger button and polls the live accessibility hierarchy.
     * - Failure modes: records an XCTest failure when the popup surface never appears.
     */
    private func openPaneMenu(
        _ paneMenu: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapElementReliably(paneMenu, timeout: timeout, file: file, line: line)
        XCTAssertTrue(
            waitForPaneMenuSurface(in: app, timeout: timeout),
            "Expected one pane-menu tap to present its surface within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Resolves one Settings control through the concrete accessibility role exported by its shared
     SwiftUI component.

     Retained iOS 17 evidence showed that repeatedly walking unrelated roles can quarantine the
     XCTest process even when the requested control is already visible. Callers therefore supply
     the exact role-backed query established by the production component and retained hierarchy.

     - Parameters:
       - element: Exact typed accessibility query for the control.
       - identifier: Stable identifier used in failure output.
       - timeout: Maximum passive wait for the control to appear.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: The typed query so the caller can inspect or activate the real control.
     - Side effects: Polls only the supplied accessibility role; it does not traverse fallback roles
       or synthesize input.
     - Failure modes: Records a focused XCTest failure when the exact control does not appear.
     */
    private func requireObservedSettingsElement(
        _ element: XCUIElement,
        identifier: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected Settings control '\(identifier)' through its observed accessibility role.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for one exact-role Settings element to publish a semantic accessibility value.

     - Parameters:
       - element: Exact typed accessibility query for the state owner.
       - identifier: Stable identifier used in failure output.
       - expectedDescription: Human-readable state expected by the caller.
       - timeout: Maximum passive wait for the state transition.
       - predicate: State predicate applied to the element's current value or label.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Side effects: Polls only the supplied accessibility role and does not synthesize input.
     - Failure modes: Records the last observed state when the exact owner never satisfies the
       predicate.
     */
    private func waitForObservedSettingsValue(
        _ element: XCUIElement,
        identifier: String,
        expectedDescription: String,
        timeout: TimeInterval,
        predicate: @escaping (String) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var observed = "missing"
        let reached = waitForUITestCondition(
            "Wait for \(identifier) to publish \(expectedDescription)",
            timeout: timeout
        ) {
            guard element.exists else {
                observed = "missing"
                return false
            }
            observed = element.value as? String ?? element.label
            return predicate(observed)
        }
        XCTAssertTrue(
            reached,
            "Expected '\(identifier)' to publish \(expectedDescription); last='\(observed)'.",
            file: file,
            line: line
        )
    }

    /**
     Resolves one Android-style pane-menu row, scrolling the custom popup when the row is below the
     first visible viewport.

     - Parameters:
     *   - identifier: Accessibility identifier for the pane-menu row.
     *   - app: Running application under test.
     *   - timeout: Maximum time to search while scrolling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching row that XCTest reports as hittable, or the unresolved query
     *   after failure.
     * - Side effects: swipes the `windowPaneMenu` popup surface upward while re-querying rows.
     * - Failure modes: records an XCTest failure when the row never becomes hittable.
     */
    private func requirePaneMenuItem(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let item = resolvedPaneMenuItem(identifier, in: app) {
                if waitForElementToBecomeHittable(item, timeout: 0.2) {
                    return item
                }
            }

            if let menuSurface = resolvedPaneMenuSurface(in: app) {
                menuSurface.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let item = app.buttons[identifier].firstMatch.exists
            ? app.buttons[identifier].firstMatch
            : unresolvedElement(identifier, in: app)
        XCTAssertTrue(
            item.exists && item.isHittable,
            "Expected pane menu item '\(identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        return item
    }

    private func resolvedPaneMenuItem(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let menuScrollView = app.scrollViews["windowPaneMenu"].firstMatch
        let candidates = [
            menuScrollView.buttons[identifier].firstMatch,
            app.buttons[identifier].firstMatch,
            menuScrollView.otherElements[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
        return candidates.first(where: { elementHasUsableFrame($0) })
    }

    /**
     Waits for the custom pane menu surface without recording an assertion failure.

     - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for any accessibility surface that represents the popup.
     * - Returns: `true` when a usable popup container appears before the timeout.
     * - Side effects: waits on an XCTest predicate over the live accessibility hierarchy.
     * - Failure modes: This helper cannot fail directly.
     */
    private func waitForPaneMenuSurface(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(block: { _, _ in self.resolvedPaneMenuSurface(in: app) != nil })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for pane menu surface"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed || resolvedPaneMenuSurface(in: app) != nil
    }

    /**
     Resolves the SwiftUI accessibility surface for the Android-style pane popup menu.

     SwiftUI can expose the same custom menu as a scroll view, other element, or button depending
     on the OS/XCTest runtime. The helper accepts any candidate with a usable frame so tests can
     scroll or verify the real popup surface without depending on one platform-specific element
     type.
     *
     * - Parameter app: Running application under test.
     * - Returns: The first usable popup container, or `nil` when the menu is not visible.
     * - Side effects: queries the live accessibility hierarchy only.
     * - Failure modes: This helper cannot fail directly.
     */
    private func resolvedPaneMenuSurface(in app: XCUIApplication) -> XCUIElement? {
        let candidates = [
            app.scrollViews["windowPaneMenu"].firstMatch,
            app.otherElements["windowPaneMenu"].firstMatch,
            app.buttons["windowPaneMenu"].firstMatch,
        ]
        return candidates.first(where: { elementHasUsableFrame($0) })
    }

    /**
     Verifies the visible reader-to-Search journey without launch-driven actions.

     `search-indexed` seeds only the prerequisite KJV index. The test opens Search through the
     production reader surface, types and submits the query once, verifies a rendered result row,
     then selects it once and passively observes the reader destination.

     - Side effects:
       - opens Search through the reader action surface
       - types `earth`, submits it, and selects the visible Genesis 1:2 row once each
     - Failure modes:
       - fails if Search is auto-presented, lacks its production form, renders no visible result,
         or does not navigate the reader after the single result action
     */
    func testSearchMenuEntryTypingAndResultNavigation() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        _ = openSearch(in: app)
        waitForReaderRenderedContentState(containing: "readerDestination=search", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Search should not expose iOS sheet-style Done chrome when opened from the reader."
        )

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "earth",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        waitForSearchQuery("earth", in: app, timeout: 20)
        submitSearchCriteria(in: app)

        let resultIdentifier = "searchResultRow::Genesis_1_2"
        waitForSearchResultRow(
            resultIdentifier,
            in: app,
            shouldExist: true,
            expectedContent: ["Genesis 1:2"],
            timeout: 20
        )
        let updatedReference = tapSearchResultRowAndWaitForReaderReferenceChange(
            resultIdentifier,
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Genesis 1:2"),
            "Expected selecting the Search result to navigate to Genesis 1:2, but saw '\(updatedReference)'."
        )
    }

    /**
     Exercises the production Search form's reference preflight and complete range destination.

     Android SearchResults.fetchSearchResults asks LinkControl to open a reference before indexed
     lookup. This journey submits once through the real form and observes both endpoint verses in
     the reader. Native reference tests own exact ordinal and versification assertions.

     - Inputs: The indexed KJV fixture and the independently chosen Genesis 2:1-3 reference.
     - Side effects: Opens Search, types one query, and submits it once.
     - Failure modes: Fails if the query remains indexed Search, is dropped, or loses either visible
       endpoint when the production callback reaches the reader.
     */
    func testSearchReferenceSubmissionOpensCompleteRange() {
        let app = makeApp()
        app.launch()
        _ = openSearch(in: app)

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "Genesis 2:1-3",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        submitSearchCriteria(in: app)

        waitForVisibleReaderText(containing: "Thus the heavens and the earth", in: app)
        waitForVisibleReaderText(containing: "And God blessed the seventh day", in: app)
        XCTAssertFalse(searchField.exists, "An accepted reference should dismiss the Search form.")
    }

    /**
     Exercises a Strong's field query through the production Search form.

     Android SearchControl preserves the strong: field while SearchResults performs its reference
     preflight. The fixture supplies one H0430 lexical hit and its visible preview. A fresh Search
     must display that hit after one submission, rather than coercing the identifier into a Bible
     reference. Policy tests separately cover malformed and out-of-range inputs.

     - Inputs: The existing indexed KJV fixture, including its independently seeded lexical facet.
     - Side effects: Opens Search, types strong:H0430, and submits it once.
     - Failure modes: Fails if production wiring bypasses Strong's routing, dismisses Search, or
       displays no corresponding visible result.
     */
    func testSearchStrongsSubmissionDisplaysIndexedOccurrence() {
        let app = makeApp()
        app.launch()
        _ = openSearch(in: app)

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "strong:H0430",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        submitSearchCriteria(in: app)

        waitForSearchResultRow(
            "searchResultRow::Genesis_1_2",
            in: app,
            shouldExist: true,
            expectedContent: ["Genesis 1:2", "Spirit of God moved upon the face of the waters"],
            timeout: 20
        )
    }

    /**
     Verifies a single-translation Search row visibly retains the complete indexed preview.

     Pinned Android MultiSearchItemAdapter renders single matches without a line limit. The
     dedicated fixture provides the complete 259-character KJV Genesis 3:17 preview; its final
     phrase lies beyond the former 200- and 240-character caps. Source-ingestion tests separately
     establish how the indexed preview is produced.

     - Inputs: The search-complete-preview index and one ordinary text query, hearkened.
     - Side effects: Opens Search and submits the query once, then reads only the row's pixels.
     - Failure modes: Fails if the real row is absent, clipped, truncated, or has lost either end of
       its text. A full accessibility label cannot compensate for missing visible text.
     */
    func testSearchSingleResultDisplaysCompleteIndexedPreview() {
        let app = makeApp()
        app.launch()
        _ = openSearch(in: app)
        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "hearkened",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        submitSearchCriteria(in: app)

        let row = app.buttons["searchResultRow::Genesis_3_17"].firstMatch
        let expectedFragments = [
            "And unto Adam he said",
            "cursed is the ground for thy sake",
            "days of thy life",
        ]
        assertVisibleSearchPreview(row, in: app, containing: expectedFragments)
    }

    /**
     Preserves Android's two-line grouped header and complete expanded translation previews.

     - Inputs: Two indexed translations of the same long verse in the dedicated multi-preview
       fixture. Android MultiSearchItemAdapter limits only the grouped header, then presents full
       source text for each translation after its arrow action.
     - Side effects: Selects both translations through the real dialog, submits one query, expands
       the result once, and scrolls only if needed to reveal the second translation.
     - Failure modes: Fails if the header loses its preview or expands prematurely, either expanded
       translation is truncated, or expansion navigates away instead of revealing its rows.
     */
    func testSearchExpandedTranslationsDisplayCompleteIndexedPreviews() {
        let app = makeApp()
        app.launch()
        _ = openSearch(in: app)
        // Production autofocus changes the form's viewport. Observe its visible keyboard before
        // revealing the below-fold selector, so the single action never targets a moving row.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let translationButton = requireElement("searchTranslationPickerButton", in: app, timeout: 10)
        let criteria = app.scrollViews.containing(
            .button,
            identifier: "searchTranslationPickerButton"
        ).firstMatch
        XCTAssertTrue(criteria.waitForExistence(timeout: 10))
        if !criteria.frame.insetBy(dx: 0, dy: 8).contains(translationButton.frame) {
            criteria.swipeUp()
        }
        XCTAssertTrue(criteria.frame.contains(translationButton.frame))
        tapElementReliably(translationButton, timeout: 10)
        let selectAll = requireElement("searchTranslationPickerSelectToggleButton", in: app, timeout: 10)
        XCTAssertEqual(selectAll.value as? String, "selectAll")
        tapElementReliably(selectAll, timeout: 10)
        XCTAssertEqual(selectAll.value as? String, "selectNone")
        let apply = requireElement("searchTranslationPickerApplyButton", in: app, timeout: 10)
        tapElementReliably(apply, timeout: 10)
        waitForElementToDisappear(apply, timeout: 10)

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "hearkened",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        submitSearchCriteria(in: app)
        let header = app.buttons["searchResultRow::Genesis_3_17"].firstMatch
        assertVisibleSearchPreview(
            header,
            in: app,
            containing: ["And unto Adam he said"],
            excluding: ["days of thy life"]
        )
        for module in ["KJV", "AATESTWEB"] {
            XCTAssertTrue(
                requireElement("searchResultModuleRow::Genesis_3_17::\(module)", in: app, timeout: 10).exists
            )
        }
        tapElementReliably(
            requireElement("searchResultExpand::Genesis_3_17", in: app, timeout: 10),
            timeout: 10
        )
        for module in ["KJV", "AATESTWEB"] {
            let row = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "searchExpandedResult::",
                "\(module):"
            )).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            if !app.frame.contains(row.frame) {
                // This gesture reveals an existing result; it never repeats the expand action.
                requireElement("searchResultsList", in: app, timeout: 10).swipeUp()
            }
            assertVisibleSearchPreview(
                row,
                in: app,
                containing: ["And unto Adam he said", "days of thy life"]
            )
        }
    }

    /**
     Passively recognizes only the visible pixels of one completely on-screen Search row.

     Positive fragments reject blank output; optional excluded fragments distinguish a collapsed
     header from its complete expanded content. Accessibility labels locate rows but never satisfy
     the content assertion. Failure retains the actual screenshot and recognized text.
     */
    private func assertVisibleSearchPreview(
        _ row: XCUIElement,
        in app: XCUIApplication,
        containing expectedFragments: [String],
        excluding excludedFragments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var observedText = ""
        var recognitionError: String?
        let visible = waitForUITestCondition("Visible Search preview", timeout: 20) {
            guard row.exists, self.elementHasUsableFrame(row), app.frame.contains(row.frame),
                  let pixels = row.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])
                observedText = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                recognitionError = nil
                return expectedFragments.allSatisfy {
                    observedText.range(of: $0, options: .caseInsensitive) != nil
                } && excludedFragments.allSatisfy {
                    observedText.range(of: $0, options: .caseInsensitive) == nil
                }
            } catch {
                recognitionError = error.localizedDescription
                return false
            }
        }
        if !visible {
            XCTContext.runActivity(named: "Incomplete visible Search preview") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let observation = XCTAttachment(string:
                    "Recognized row text: \(observedText)\nError: \(recognitionError ?? "none")"
                )
                observation.lifetime = .keepAlways
                activity.add(observation)
            }
        }
        XCTAssertTrue(
            visible,
            "Expected the specified preview fragments in the Search row's visible pixels.",
            file: file,
            line: line
        )
    }

    /**
     Reproduces a two-document scripture switch directly from Android's reader toolbar shortcut.

     The custom-theme fixture installs KJV and AATESTWEB, which makes the toolbar's two-document
     action switch immediately instead of opening a picker. Its distinct global, workspace, and
     window settings make a resolved-preference regression observable in the passive reader state.
     Keeping this path separate from Search and Choose Document isolates reader content/theme state
     reloading from destination-pop animations.

     - Side effects:
       - launches the deterministic two-Bible fixture with scoped custom colors in day mode
       - taps the production Bible toolbar action once
       - waits for the alternate Bible to become the rendered pane document
     - Failure modes:
       - fails if the fixture does not start on KJV
       - fails if the toolbar shortcut cannot switch to AATESTWEB
       - fails if either side of the switch loses the resolved window-scoped day background value
     */
    func testReaderQuickScriptureSwitchPreservesDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapElementReliably(
            requireElement("readerBibleToolbarButton", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
    }

    /**
     Proves the real Bible quick popup keeps a late installed source reachable in a bounded viewport.

     The fixture registers 59 readable aliases over one KJV payload, yielding exactly 60 Bible rows
     without copying the large fixture body. This journey opens the production toolbar popup,
     verifies the real inner scroll viewport is usable and on screen, scrolls until the final alias
     is visible, selects it once, and observes the exact native source identity plus the complete
     real first verse.
     */
    func testBibleQuickSelectorScrollsToLateReadableModuleAndPublishesIt() {
        let app = makeApp()
        app.launch()
        let bookChooser = requireElement("bookChooserButton", in: app, timeout: 20)
        XCTAssertTrue(
            waitForUITestCondition("real KJV publication before long quick-menu action", timeout: 20) {
                guard let value = bookChooser.value as? String else { return false }
                return value.localizedCaseInsensitiveContains("Genesis 1") &&
                    value.localizedCaseInsensitiveContains("King James Version (1769)")
            }
        )
        waitForVisibleReaderText(
            containing: "In the beginning God created the heaven and the earth.",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 20))
        _ = requireElement("readerBibleQuickSelector", in: app, timeout: 10)
        let scrollSurface = app.scrollViews["readerBibleQuickSelectorScrollView"].firstMatch
        XCTAssertTrue(
            scrollSurface.waitForExistence(timeout: 10),
            "Expected the quick selector to expose its real vertical scroll surface."
        )
        let scrollFrame = scrollSurface.frame
        XCTAssertTrue(elementFrameIsUsable(scrollFrame))
        XCTAssertTrue(scrollSurface.isHittable)
        XCTAssertTrue(
            app.frame.insetBy(dx: -1, dy: -1).contains(scrollFrame),
            "Expected the real quick-selector viewport to remain inside the visible app bounds."
        )
        XCTAssertLessThan(
            scrollFrame.height,
            app.frame.height,
            "Expected a bounded scroll viewport rather than an off-screen 60-row stack."
        )

        let targetRow = unresolvedElement("readerBibleQuickSelectorRow_UITESTQ58", in: app)
        XCTAssertFalse(
            isElementVisible(targetRow, within: scrollSurface),
            "The final alias should begin below the quick popup viewport."
        )
        for _ in 0..<12 {
            if isElementVisible(targetRow, within: scrollSurface) { break }
            scrollSurface.swipeUp()
        }
        XCTAssertTrue(
            isElementVisible(targetRow, within: scrollSurface),
            "Expected vertical popup scrolling to reveal the final installed Bible alias."
        )
        XCTAssertEqual(targetRow.label, "UITESTQ58 (en)")
        XCTAssertEqual(targetRow.value as? String, "available")
        tapElementReliably(targetRow)

        waitForReaderRenderedContentState(
            containing: "category=bible;module=UITESTQ58",
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            waitForUITestCondition("late alias header publication", timeout: 20) {
                guard let value = bookChooser.value as? String else { return false }
                return value.localizedCaseInsensitiveContains("Genesis 1") &&
                    value.localizedCaseInsensitiveContains("UI Test Quick Bible 58")
            }
        )
        waitForVisibleReaderText(
            containing: "In the beginning God created the heaven and the earth.",
            in: app,
            timeout: 20
        )
        XCTAssertFalse(
            unresolvedElement("readerBibleQuickSelector", in: app).exists,
            "Selecting the late row should dismiss the quick popup."
        )
    }

    /**
     Verifies Android's fixed-dark passage chooser cannot mutate a System/day reader into night mode.

     The fixture explicitly selects System night mode, seeds visibly different day/night window
     colors, and launches the simulator in light appearance. Android presents its chooser in a
     separately themed activity with theme changes disabled; the journey verifies that opening and
     closing the chooser does not mutate the reader's resolved mode or background configuration.

     - Side effects:
       - launches the custom-theme fixture in explicit System/day mode
       - opens the production passage chooser and observes reader state while it remains presented
       - selects Genesis 2 and waits for the destination pop to finish
     - Failure modes:
       - fails if opening the chooser changes `nightMode` to true or selects the night background
       - fails if choosing Genesis 2 does not return to the same day-themed reader
       - fails if the reader state export becomes unavailable while the chooser is presented
     - Note: The negative observation spans the stable open chooser, where the former feedback loop
       held night mode true; it does not depend on sampling a single animation frame.
     */
    func testPassageChooserPreservesSystemDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))
        let unexpectedNightBackground = Int(Int32(bitPattern: 0xFF2B183C))

        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapElementReliably(
            requireElement("bookChooserButton", in: app, timeout: 20),
            timeout: 20
        )
        XCTAssertTrue(requireElement("passageChooserScreen", in: app, timeout: 20).exists)
        let chooserReaderState = app.staticTexts["readerRenderedContentState"].firstMatch
        XCTAssertTrue(
            chooserReaderState.waitForExistence(timeout: 5),
            "Expected the chooser destination's reader-state export to remain available."
        )
        let expectedDayState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@",
                "readerDestination=passageChooser",
                "nightMode=false",
                "readerBackground=\(expectedBackground)"
            ),
            object: chooserReaderState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectedDayState], timeout: 5),
            .completed,
            "Expected the open chooser to retain the System/day reader state."
        )
        let unexpectedNightState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ OR value CONTAINS %@",
                "nightMode=true",
                "readerBackground=\(unexpectedNightBackground)"
            ),
            object: chooserReaderState
        )
        unexpectedNightState.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [unexpectedNightState], timeout: 1.5),
            .completed,
            "The fixed-dark chooser must not be interpreted as a dark system appearance."
        )

        tapElementReliably(
            app.buttons["passageBookCell.Gen"].firstMatch,
            timeout: 20
        )
        tapElementReliably(
            app.buttons["passageChapterCell.2"].firstMatch,
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "readerDestination=none",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            requireReaderReferenceValue(in: app, timeout: 20)
                .localizedCaseInsensitiveContains("Genesis 2"),
            "Expected passage selection to return to Genesis 2 in the original reader."
        )
    }

    /**
     Reproduces scripture replacement through Android's full Choose Document activity.

     This is the reported regression path: the current custom day-themed reader opens the app-owned
     document chooser, activates another installed Bible, and returns through the same reader stack.
     Global, workspace, and window fixtures use different values, so the exported resolved state
     distinguishes a lost window override from a mode change or application-default fallback. It
     complements the toolbar test so a failure can be attributed to destination dismissal or to the
     shared controller reload.

     - Side effects:
       - launches KJV/AATESTWEB with distinct global/workspace/window palettes in day mode
       - opens Choose Document through the production reader action
       - filters and selects AATESTWEB, then waits for the reader destination to close
     - Failure modes:
       - fails if Choose Document cannot open or expose the seeded module
       - fails if selection does not render AATESTWEB in the original pane
       - fails if the night policy or resolved window-scoped day background changes
     */
    func testDocumentChooserScriptureSwitchPreservesDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )
        let searchField = requireElement("modulePickerSearchField", in: app, timeout: 20)
        replaceText(in: searchField, with: "AATESTWEB", placeholderHints: ["Search"])
        tapElementReliably(
            requireElement("modulePickerRow::AATESTWEB", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
    }

    /**
     Reproduces scripture replacement while a non-default night palette is active.

     The fixture's window-scoped purple night background differs from its workspace blue, global
     blue-black, and Vue default black. That distinction catches a resolved configuration fallback
     even when the Boolean night-mode policy itself remains unchanged. The journey does not claim a
     pixel assertion for SwiftUI chrome.

     - Side effects:
       - launches the deterministic KJV/AATESTWEB fixture in manual night mode
       - opens Choose Document, filters to AATESTWEB, and activates that Bible
       - returns to the reader with the configured night policy still active
     - Failure modes:
       - fails if the custom-night fixture does not start on KJV in night mode
       - fails if selection does not render AATESTWEB in the original pane
       - fails if either side of the switch loses the resolved window-scoped night background value
     */
    func testDocumentChooserScriptureSwitchPreservesCustomNightTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFF2B183C))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=true", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )
        let searchField = requireElement("modulePickerSearchField", in: app, timeout: 20)
        replaceText(in: searchField, with: "AATESTWEB", placeholderHints: ["Search"])
        tapElementReliably(
            requireElement("modulePickerRow::AATESTWEB", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=true", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
    }

    /**
     Guards the shared text-entry placeholder normalization against SwiftUI prompt fields whose
     placeholder values surface through XCUI as `Optional(...)`.
     *
     * - Side effects: none.
     * - Failure modes:
     *   - fails if Optional-wrapped placeholder text no longer normalizes to the placeholder value
     */
    func testTextEntrySemanticValueCandidatesUnwrapOptionalPlaceholderForms() {
        let plainOptionalCandidates = textEntrySemanticValueCandidates(from: "Optional(Label name)")
        XCTAssertTrue(
            plainOptionalCandidates.contains("label name"),
            "Expected Optional(Label name) to normalize to the placeholder text."
        )

        let quotedOptionalCandidates = textEntrySemanticValueCandidates(from: "Optional(\"Name\")")
        XCTAssertTrue(
            quotedOptionalCandidates.contains("name"),
            "Expected Optional(\"Name\") to normalize to the placeholder text."
        )
    }

    /**
     Verifies the Android margins editor's maximum text width narrows the rendered reader text.
     *
     Package tests prove the `set_config` payload carries `marginSize`, so this smoke guards the
     remaining production chain: the margins dialog commit, the reader refresh push, and the shared
     Vue content layout actually constraining visible text (issue #377 reported no visible effect).
     Draft-versus-committed persistence stays in package tests; this smoke asserts only the
     rendered outcome.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - reduces the workspace maximum text width through the real margins editor dialog
     * - Failure modes:
     *   - fails if the margins dialog, its seek bar, or its OK action cannot be reached
     *   - fails if reader text never renders, disappears after the commit, or keeps its width
     */
    func testMarginMaxWidthEditorNarrowsRenderedReaderText() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 30))
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20))
        var initialWidth: CGFloat = 0
        XCTAssertTrue(
            waitForUITestCondition("initial reader text renders", timeout: 20) {
                initialWidth = self.widestTextLineWidth(in: webView)
                return initialWidth > 100
            },
            "Expected measurable rendered reader text before editing margins."
        )
        attachReaderScreenshot(named: "reader-before-margin-edit", of: app)

        let textDisplayScreen = openAllTextOptions(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayMarginSizeButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            requireObservedSettingsElement(
                app.otherElements["textDisplayPreferenceEditorDialog"].firstMatch,
                identifier: "textDisplayPreferenceEditorDialog",
                timeout: 10
            ).exists
        )

        let maxWidthSlider = requireObservedSettingsElement(
            app.sliders["textDisplayPreferenceEditorSeekBar::Maximum width of text"].firstMatch,
            identifier: "textDisplayPreferenceEditorSeekBar::Maximum width of text",
            timeout: 10
        )
        dragSeekBar(maxWidthSlider, fromNormalizedX: 0.34, toNormalizedX: 0.1)
        XCTAssertLessThan(
            seekBarNumericValue(maxWidthSlider),
            120,
            "Expected the seek bar drag to reduce the drafted maximum width below its 170 default."
        )

        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplayPreferenceEditorOKButton"].firstMatch,
                identifier: "textDisplayPreferenceEditorOKButton",
                timeout: 10
            ),
            timeout: 10
        )
        tapElementReliably(
            requireObservedSettingsElement(
                app.buttons["textDisplaySettingsTopAppBarBackButton"].firstMatch,
                identifier: "textDisplaySettingsTopAppBarBackButton",
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 20))

        var narrowedWidth: CGFloat = 0
        let didNarrow = waitForUITestCondition("reader text narrows", timeout: 20) {
            narrowedWidth = self.widestTextLineWidth(in: webView)
            return narrowedWidth > 0 && narrowedWidth < initialWidth * 0.8
        }
        attachReaderScreenshot(named: "reader-after-margin-edit", of: app)
        XCTAssertTrue(
            didNarrow,
            "Expected a much smaller maximum text width to narrow rendered reader text; "
                + "initial=\(initialWidth) final=\(narrowedWidth)"
        )
        XCTAssertGreaterThan(
            narrowedWidth,
            0,
            "Expected the reader to keep rendering text after the margin commit."
        )
    }

    /**
     Attaches one always-kept reader screenshot for visual diagnosis of layout assertions.
     *
     * - Parameters:
     *   - name: Stable attachment name recorded in the result bundle.
     *   - app: Running application under test.
     * - Side effects: Adds one XCTAttachment to the current test.
     * - Failure modes: none; attachment capture failures surface through XCTest itself.
     */
    private func attachReaderScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /**
     Verifies the Android font-size editor visibly changes rendered reader text.
     *
     Issue #377 hid in the gap between a correct `set_config` payload and native CSS overriding the
     rendered result, so payload-level tests alone cannot protect display settings. This smoke
     drives the real font-size editor to a much larger value and asserts the rendered text lines
     grow, closing that gap for the second-most-used text display setting.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - raises the workspace font size through the real editor dialog
     * - Failure modes:
     *   - fails if the font-size dialog, its seek bar, or its OK action cannot be reached
     *   - fails if rendered reader text keeps its previous line height after the commit
     */
    func testFontSizeEditorGrowsRenderedReaderText() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 30))
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20))
        var initialHeight: CGFloat = 0
        XCTAssertTrue(
            waitForUITestCondition("initial reader text renders", timeout: 20) {
                initialHeight = self.tallestTextLineHeight(in: webView)
                return initialHeight > 10
            },
            "Expected measurable rendered reader text before editing font size."
        )

        let textDisplayScreen = openAllTextOptions(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        tapElementReliably(
            requireReachableTextDisplayButton("textDisplayFontSizeButton", in: app, timeout: 10),
            timeout: 10
        )
        let fontSizeSlider = requireElement(
            "textDisplayPreferenceEditorSeekBar::Font size",
            in: app,
            timeout: 10
        )
        dragSeekBar(fontSizeSlider, fromNormalizedX: 0.3, toNormalizedX: 0.9)
        XCTAssertGreaterThan(
            seekBarNumericValue(fontSizeSlider),
            35,
            "Expected the seek bar drag to raise the drafted font size well above its default."
        )
        tapElementReliably(
            requireElement("textDisplayPreferenceEditorOKButton", in: app, timeout: 10),
            timeout: 10
        )
        tapElementReliably(
            requireElement("textDisplaySettingsTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 20))

        var grownHeight: CGFloat = 0
        let didGrow = waitForUITestCondition("reader text grows", timeout: 20) {
            grownHeight = self.tallestTextLineHeight(in: webView)
            return grownHeight > initialHeight * 1.5
        }
        XCTAssertTrue(
            didGrow,
            "Expected a much larger font size to grow rendered reader text lines; "
                + "initial=\(initialHeight) final=\(grownHeight)"
        )
    }

    /**
     Drags an Android seek bar thumb between two normalized horizontal positions.
     *
     * - Parameters:
     *   - element: Seek bar whose drag gesture should receive the interaction.
     *   - fromNormalizedX: Approximate current thumb position in normalized element space.
     *   - toNormalizedX: Target position in normalized element space.
     * - Side effects: Performs one press-and-drag interaction on the element.
     * - Failure modes: none directly; callers assert the resulting accessibility value.
     */
    private func dragSeekBar(
        _ element: XCUIElement,
        fromNormalizedX: CGFloat,
        toNormalizedX: CGFloat
    ) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: fromNormalizedX, dy: 0.5))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: toNormalizedX, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    /**
     Reads the Android seek bar's numeric accessibility value.
     *
     * - Parameter element: Seek bar element exposing its bound value as accessibility value.
     * - Returns: Parsed numeric value, or `greatestFiniteMagnitude` when unavailable so callers'
     *   less-than assertions fail loudly.
     * - Side effects: none.
     * - Failure modes: Missing or non-numeric accessibility values return the sentinel maximum.
     */
    private func seekBarNumericValue(_ element: XCUIElement) -> Double {
        Double((element.value as? String) ?? "") ?? .greatestFiniteMagnitude
    }

    /**
     Captures one complete accessibility sample of rendered reader text frames.
     *
     * WebKit can omit its remote descendants from a root snapshot even while those descendants
     remain queryable. Resolving the descendant query directly preserves that remote boundary, and
     requiring the fixture's first 40 text runs prevents a temporarily truncated tree from becoming
     evidence that reader geometry changed.
     *
     * - Parameter webView: Reader web view element already confirmed to exist.
     * - Returns: The first 40 static-text frames, or `nil` when WebKit cannot provide the complete
     *   deterministic sample.
     * - Side effects: Resolves the WebKit static-text query and captures 40 read-only snapshots.
     * - Failure modes: Returns `nil` when fewer than 40 descendants are exposed or any snapshot
     *   fails, changes type, or exposes unusable geometry. Every collected frame is discarded so
     *   polling callers cannot accept a partial sample.
     */
    private func sampledStaticTextFrames(in webView: XCUIElement) -> [CGRect]? {
        let requiredSampleCount = 40
        let textElements = Array(
            webView.staticTexts.allElementsBoundByAccessibilityElement.prefix(requiredSampleCount)
        )
        guard textElements.count == requiredSampleCount else { return nil }

        var frames: [CGRect] = []
        frames.reserveCapacity(textElements.count)
        for textElement in textElements {
            guard let snapshot = try? textElement.snapshot(),
                  snapshot.elementType == .staticText,
                  elementFrameIsUsable(snapshot.frame) else {
                return nil
            }
            frames.append(snapshot.frame)
        }
        return frames
    }

    /**
     Measures the tallest rendered text line inside an existing reader web view.
     *
     * - Parameter webView: Reader web view element already confirmed to exist.
     * - Returns: Height of the tallest static text run, or zero when no complete sample is exposed.
     * - Side effects: Captures one complete read-only WebKit accessibility sample.
     * - Failure modes: Snapshot failure returns zero so the enclosing polling assertion retries;
     *   partial measurements are never published as evidence that layout changed.
     */
    private func tallestTextLineHeight(in webView: XCUIElement) -> CGFloat {
        guard let frames = sampledStaticTextFrames(in: webView) else { return 0 }
        return frames.map(\.height).max() ?? 0
    }

    /**
     Measures the widest rendered text line inside an existing reader web view.
     *
     * - Parameter webView: Reader web view element already confirmed to exist.
     * - Returns: Width of the widest static text run, or zero when no complete sample is exposed.
     * - Side effects: Captures one complete read-only WebKit accessibility sample.
     * - Failure modes: Snapshot failure returns zero so the enclosing polling assertion retries;
     *   partial measurements are never published as evidence that layout changed.
     */
    private func widestTextLineWidth(in webView: XCUIElement) -> CGFloat {
        guard let frames = sampledStaticTextFrames(in: webView) else { return 0 }
        return frames.map(\.width).max() ?? 0
    }

}
