import Foundation
import Darwin
import Vision
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the drawer Reading Plan route can select, advance, reset, and import plans.
     *
     * Android opens the selector through `DailyReading`, returns the chosen plan code, and then
     * immediately shows that plan's daily reading. Package tests own bundled catalog parity, custom
     * parsing, and persistence details; this smoke keeps one visible route through the production
     * reader menu and user controls.
     *
     * - Side effects:
     *   - launches the reader shell with empty reading-plan state
     *   - opens Reading Plans from the drawer and verifies Android-style destination chrome
     *   - starts the first Android-parity built-in template, completes day one, and reopens day two
     *   - resets through Daily Reading's overflow, then opens Import from that same source menu
     * - Failure modes:
     *   - fails if Reading Plans regresses to sheet presentation
     *   - fails if the coordinator state does not publish the expected selected-plan lifecycle
     *   - fails if the built-in catalog diverges from Android's bundled templates
     *   - fails if the built-in template does not navigate from picker selection to Daily Reading
     *   - fails if the daily reading route cannot complete today's due reading through the visible controls
     *   - fails if Reset does not use Android's overflow/confirmation/finish lifecycle
     *   - fails if Import is incorrectly placed in the selector or does not request ZIP selection
     */
    func testReadingPlansRouteSelectAdvanceResetAndImportAffordanceFlow() {
        let builtInPlanCode = "y1ot1nt1_OTthenNT"
        let builtInPlanToken = readingPlanStateToken(builtInPlanCode)
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=readingPlans", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Reading Plan should use reader destination back chrome, not iOS sheet Done chrome."
        )
        waitForReadingPlanListState(containing: "total=0", in: app, timeout: 10)
        waitForReadingPlanListState(containing: "showAvailablePlans=true", in: app, timeout: 10)

        openAvailableReadingPlans(in: app, timeout: 10)
        waitForReadingPlanListState(containing: "templates=7", in: app, timeout: 10)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        XCTAssertTrue(
            requireElement("dailyReadingScreen", in: app, timeout: 20).exists,
            "Choosing a reading-plan template should continue directly to Daily Reading."
        )
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertEqual(currentDay.value as? String, "1")

        tapElementReliably(
            requireElement("dailyReadingStatusToggle::1", in: app, timeout: 10),
            timeout: 10
        )
        let doneButton = requireElement("dailyReadingDoneButton", in: app, timeout: 10)
        XCTAssertTrue(
            waitForUITestCondition("Daily Reading Done button enabled", timeout: 10) {
                doneButton.isEnabled
            },
            "Android enables Done only after every reading for the day is marked read."
        )
        tapElementReliably(doneButton, timeout: 10)
        XCTAssertTrue(
            waitForUITestCondition("Daily Reading closes to reader", timeout: 20) {
                self.readerRenderedContentStateValue(in: app)?.contains(
                    "readerDestination=none"
                ) == true
            },
            "Android finishes Daily Reading when the next plan day is not yet due."
        )

        _ = openReadingPlans(in: app, timeout: 20)
        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 20).exists)
        let advancedDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertTrue(
            waitForUITestCondition("persisted reading-plan day two", timeout: 10) {
                advancedDay.value as? String == "2"
            },
            "Done must persist Android's next current day before dismissing Daily Reading."
        )
        tapElementReliably(
            openDailyReadingOverflowItem("dailyReadingResetPlanButton", in: app),
            timeout: 10
        )
        tapElementReliably(
            requireElement(
                "dailyReadingResetConfirmationDialogAction::yes",
                in: app,
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(
            waitForUITestCondition("Reset closes Daily Reading to reader", timeout: 20) {
                self.readerRenderedContentStateValue(in: app)?.contains(
                    "readerDestination=none"
                ) == true
            }
        )

        _ = openReadingPlans(in: app, timeout: 20)
        openAvailableReadingPlans(in: app, timeout: 10)
        waitForReadingPlanListState(containing: "total=0", in: app, timeout: 10)
        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 20).exists)

        tapElementReliably(
            openDailyReadingOverflowItem("readingPlanImportButton", in: app),
            timeout: 10
        )
        waitForReadingPlanListState(containing: "importPickerPresented=true", in: app, timeout: 20)
    }

    /**
     Opens Daily Reading's app-owned overflow and resolves one source menu command.

     - Parameters:
       - itemIdentifier: Stable identifier of the Android overflow row.
       - app: Running application currently showing Daily Reading.
       - timeout: Maximum time to open and resolve the popup.
       - file: XCTest failure attribution source.
       - line: XCTest failure attribution line.
     - Returns: Visible, usable popup command.
     - Side effects: Taps the real Daily Reading overflow trigger when necessary.
     - Failure modes: Records a focused failure if the trigger or command never becomes visible.
     */
    func openDailyReadingOverflowItem(
        _ itemIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let item = resolvedElement(itemIdentifier, in: app),
           elementHasUsableFrame(item) {
            return item
        }

        let trigger = requireElement(
            "dailyReadingActionsMenuButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        tapElementReliably(trigger, timeout: timeout, file: file, line: line)

        var resolvedItem: XCUIElement?
        let didResolveItem = waitForUITestCondition(
            "Daily Reading overflow item '\(itemIdentifier)'",
            timeout: timeout
        ) {
            guard let item = self.resolvedElement(itemIdentifier, in: app),
                  self.elementHasUsableFrame(item)
            else {
                return false
            }
            resolvedItem = item
            return true
        }
        if didResolveItem, let resolvedItem {
            return resolvedItem
        }

        let fallback = unresolvedElement(itemIdentifier, in: app)
        XCTAssertTrue(
            fallback.exists,
            "Expected Daily Reading overflow item '\(itemIdentifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallback
    }

    /**
     Opens the Downloads overflow popup and resolves one visible action row.
     *
     * Android exposes repository management from the Downloads overflow menu. The iOS route mirrors
     * that with a custom SwiftUI popup, so tests must verify the popup is actually open before tapping
     * rows instead of treating a toolbar tap as enough synchronization.
     *
     * - Parameters:
     *   - itemIdentifier: Accessibility identifier of the overflow row that should become visible.
     *   - app: Running application currently showing the Downloads screen.
     *   - timeout: Maximum number of seconds to keep opening and polling the popup.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved overflow row once it exposes a usable frame.
     * - Side effects:
     *   - taps the real Downloads overflow toolbar button and waits for the requested row through
     *     XCTest-backed candidate waits
     * - Failure modes:
     *   - records an XCTest failure when the toolbar button or requested row never becomes visible
     */
    func openDownloadsOverflowItem(
        _ itemIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let itemCandidates = [
            unresolvedElement(itemIdentifier, in: app),
            app.buttons[itemIdentifier].firstMatch,
            app.cells[itemIdentifier].firstMatch,
            app.otherElements[itemIdentifier].firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        if let item = firstVisibleCandidate(from: itemCandidates, waitTimeout: min(1, timeout)) {
            return item
        }

        let overflowButton = unresolvedElement("moduleBrowserOverflowButton", in: app)
        tapElementReliably(overflowButton, timeout: timeout, file: file, line: line)
        if let item = firstVisibleCandidate(
            from: itemCandidates,
            waitTimeout: max(0, deadline.timeIntervalSinceNow)
        ) {
            return item
        }

        let item = unresolvedElement(itemIdentifier, in: app)
        XCTAssertTrue(
            elementHasUsableFrame(item),
            "Expected Downloads overflow item '\(itemIdentifier)' to become visible within \(timeout) seconds.",
            file: file,
            line: line
        )
        return item
    }

    /**
     Verifies Choose Document and Download Documents render as the same full Android activity family.

     This is the live regression counterpart to the source-level ownership matrix. It protects the
     reported failure where Choose Document became a large-type, History-like constrained modal by
     requiring the real reader route to expose the shared app bar and all three inline
     `DocumentSelectionBase` filters, then transitions through its real overflow action and compares
     their geometry with Download Documents.

     - Side effects:
       - launches the reader, opens Choose Document, opens its app-owned overflow popup, and follows
         the Download Documents action on the same reader destination stack
     - Failure modes:
       - fails if either activity loses its app-owned Back/overflow controls or shared filters
       - fails if Choose Document is hosted as a History dialog or native iOS sheet
       - fails if the shared filter controls no longer occupy equivalent activity geometry
     */
    func testDocumentChooserMatchesDownloadDocumentsActivityStructure() {
        let app = makeApp()
        app.launch()

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )

        let chooserBack = requireElement("modulePickerBackButton", in: app, timeout: 20)
        let chooserOverflow = requireElement("modulePickerOverflowButton", in: app, timeout: 10)
        let chooserLanguage = requireElement("modulePickerLanguageFilter", in: app, timeout: 10)
        let chooserSearch = requireElement("modulePickerSearchField", in: app, timeout: 10)
        let chooserCategory = requireElement("modulePickerCategoryFilter", in: app, timeout: 10)
        let chooserFrames = (
            back: chooserBack.frame,
            language: chooserLanguage.frame,
            search: chooserSearch.frame,
            category: chooserCategory.frame
        )

        XCTAssertFalse(
            unresolvedElement("androidHistoryDialog", in: app).exists,
            "Choose Document must not reuse the constrained History dialog host."
        )
        XCTAssertFalse(
            app.sheets.firstMatch.exists,
            "Choose Document must remain an app-owned activity rather than a native iOS sheet."
        )
        XCTAssertLessThan(
            chooserFrames.search.midY,
            app.frame.midY,
            "The shared document filter strip must remain in the activity header, not a centered modal."
        )

        tapElementReliably(chooserOverflow, timeout: 10)
        tapElementReliably(
            requireElement("modulePickerDownloadsButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForReaderRenderedContentState(
            containing: "readerDestination=downloads",
            in: app,
            timeout: 20
        )

        let downloadsBack = requireElement("moduleBrowserBackButton", in: app, timeout: 20)
        _ = requireElement("moduleBrowserOverflowButton", in: app, timeout: 10)
        let downloadsLanguage = requireElement("moduleBrowserLanguageFilter", in: app, timeout: 10)
        let downloadsSearch = requireElement("moduleBrowserSearchField", in: app, timeout: 10)
        let downloadsCategory = requireElement("moduleBrowserCategoryFilter", in: app, timeout: 10)

        XCTAssertEqual(chooserFrames.back.height, downloadsBack.frame.height, accuracy: 2)
        XCTAssertEqual(chooserFrames.language.minY, downloadsLanguage.frame.minY, accuracy: 2)
        XCTAssertEqual(chooserFrames.search.minY, downloadsSearch.frame.minY, accuracy: 2)
        XCTAssertEqual(chooserFrames.search.height, downloadsSearch.frame.height, accuracy: 2)
        XCTAssertEqual(chooserFrames.category.minY, downloadsCategory.frame.minY, accuracy: 2)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    /**
     Verifies Downloads repository management from the reader-owned route.

     Repository add, replace, delete, and reset persistence runs in `RepositorySourceManagerTests`
     because that is the SwordKit-owned source-management contract. This UI smoke intentionally
     stays at the visible route boundary while still proving the real reader menu opens Downloads
     and Android's Downloads overflow exposes Custom repositories. Workspace graph persistence and
     prompt behavior stay covered by workspace-specific package and UI contracts instead of being
     coupled to this Downloads route smoke.
     *
     * - Side effects:
     *   - launches the reader shell
     *   - opens Downloads from the real reader menu
     *   - opens the repository manager from Android's Downloads overflow menu
     * - Failure modes:
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the repository manager loses the visible add-source affordance
     */
    func testDownloadsRepositoryManagerOpensFromOverflow() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        tapElementReliably(
            openDownloadsOverflowItem("moduleBrowserRepositoriesButton", in: app, timeout: 15),
            timeout: 15
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
        XCTAssertTrue(requireElement("repositoryManagerAddButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies the real Downloads row uses Android's remote abbreviation for display, search, and order.

     The fixture's two synthetic rows have identical repository, install status, category, language,
     and recommendation state. Their initials order is the reverse of their abbreviation order, so
     the visible row order cannot pass by accidentally sorting installation identities. The search
     phrase occurs only in the first row's abbreviation. Accessibility locates the exact rows, while
     Vision verifies that the abbreviations are present in the rendered pixels.
     */
    func testDownloadsUsesRemoteAbbreviationForVisibleDisplaySearchAndOrder() {
        let source = "UITest Downloads"
        let firstIdentifier = "moduleBrowserRow::\(source)--ZZZREMOTE"
        let secondIdentifier = "moduleBrowserRow::\(source)--AAAREMOTE"
        let firstAbbreviation = "Aardvark"
        let secondAbbreviation = "Aaron"

        func assertVisibleRowPixels(
            _ row: XCUIElement,
            contain expectedText: String,
            in app: XCUIApplication
        ) {
            var observedText = ""
            var recognitionError: String?
            let rendered = waitForUITestCondition(
                "Downloads row pixels contain \(expectedText)",
                timeout: 20
            ) {
                guard row.exists,
                      self.elementHasUsableFrame(row),
                      app.frame.contains(row.frame),
                      let pixels = row.screenshot().image.cgImage else {
                    return false
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = ["en-US"]
                do {
                    try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])
                    observedText = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ")
                    recognitionError = nil
                    return observedText.range(of: expectedText, options: .caseInsensitive) != nil
                } catch {
                    recognitionError = error.localizedDescription
                    return false
                }
            }
            if !rendered {
                XCTContext.runActivity(named: "Missing visible Downloads abbreviation") { activity in
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.lifetime = .keepAlways
                    activity.add(screenshot)
                    let observation = XCTAttachment(
                        string: "Recognized row text: \(observedText)\nError: \(recognitionError ?? "none")"
                    )
                    observation.lifetime = .keepAlways
                    activity.add(observation)
                }
            }
            XCTAssertTrue(
                rendered,
                "Expected visible Downloads row pixels to contain '\(expectedText)'."
            )
        }

        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        let firstRow = requireElement(firstIdentifier, in: app, timeout: 20)
        let secondRow = requireElement(secondIdentifier, in: app, timeout: 20)
        XCTAssertEqual(firstRow.label, firstAbbreviation)
        XCTAssertEqual(secondRow.label, secondAbbreviation)
        assertVisibleRowPixels(firstRow, contain: firstAbbreviation, in: app)
        assertVisibleRowPixels(secondRow, contain: secondAbbreviation, in: app)
        XCTAssertLessThan(
            firstRow.frame.minY,
            secondRow.frame.minY,
            "Equal-rank Downloads rows must be ordered by abbreviation, not initials."
        )

        let searchField = requireElement("moduleBrowserSearchField", in: app, timeout: 10)
        replaceText(in: searchField, with: firstAbbreviation, placeholderHints: ["Search"])
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        waitForElementToDisappear(secondRow, timeout: 10)
        XCTAssertEqual(firstRow.label, firstAbbreviation)
        assertVisibleRowPixels(firstRow, contain: firstAbbreviation, in: app)
    }

    /**
     Verifies Downloads keeps row order stable through real cancellation and durable installation.

     Android's Downloads list updates the tapped row in place after `downloadDocument(...)` and does
     not re-run the install-status sort until the user rebuilds the filtered document list. The host
     fixture serves a valid SWORD package through the repository's real URLSession boundary and holds
     each transfer until cancellation or explicit release. The journey cancels the first transfer,
     completes the second without moving the active list, then relaunches and confirms Android's
     rebuilt installed-before-installable order together with the durable result.
     */
    func testDownloadsInstallKeepsRowOrderVisibleDuringActivity() {
        let source = "UITest Downloads"
        let kjvRowIdentifier = "moduleBrowserRow::\(source)--KJV"
        let recommendedRowIdentifier = "moduleBrowserRow::\(source)--UITESTDLREC"
        let warningRowIdentifier = "moduleBrowserRow::UITest Downloads--UITESTDLWARN"
        let progressIdentifier = "moduleBrowserInstallProgress::\(source)--UITESTDLWARN"
        let cancelIdentifier = "moduleBrowserCancelInstallButton::\(source)--UITESTDLWARN"
        func waitForVisiblePartialDownloadProgress(in app: XCUIApplication) {
            var observedLabel = "<missing>"
            let didObserve = waitForUITestCondition(
                "Visible Downloads byte progress advances before release",
                timeout: 10
            ) {
                guard let progress = self.resolvedElement(progressIdentifier, in: app) else {
                    return false
                }
                observedLabel = progress.label
                guard let percentageToken = observedLabel.split(separator: " ").last,
                      percentageToken.hasSuffix("%"),
                      let percent = Int(percentageToken.dropLast()) else {
                    return false
                }
                return percent > 0 && percent < 100
            }
            XCTAssertTrue(
                didObserve,
                "Expected visible partial download progress before host release; last label was "
                    + "'\(observedLabel)'."
            )
        }
        func assertActiveSessionRowOrder(in app: XCUIApplication) {
            let kjvRow = requireElement(kjvRowIdentifier, in: app, timeout: 20)
            let recommendedRow = requireElement(recommendedRowIdentifier, in: app, timeout: 20)
            let warningRow = requireElement(warningRowIdentifier, in: app, timeout: 20)
            XCTAssertLessThan(kjvRow.frame.minY, recommendedRow.frame.minY)
            XCTAssertLessThan(recommendedRow.frame.minY, warningRow.frame.minY)
        }
        func assertRebuiltInstalledRowOrder(in app: XCUIApplication) {
            let kjvRow = requireElement(kjvRowIdentifier, in: app, timeout: 20)
            let recommendedRow = requireElement(recommendedRowIdentifier, in: app, timeout: 20)
            let warningRow = requireElement(warningRowIdentifier, in: app, timeout: 20)
            XCTAssertLessThan(kjvRow.frame.minY, warningRow.frame.minY)
            XCTAssertLessThan(warningRow.frame.minY, recommendedRow.frame.minY)
        }
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        assertActiveSessionRowOrder(in: app)
        waitForElementValue(warningRowIdentifier, toEqual: "installable", in: app, timeout: 10)

        requireElement(warningRowIdentifier, in: app, timeout: 10).swipeUp()
        XCTAssertFalse(
            app.otherElements["moduleBrowserContextActionBar"].firstMatch.exists,
            "Scrolling an installable row must not enter contextual selection."
        )
        XCTAssertFalse(
            app.buttons["androidModulePickerDecisionDialogAction::install"].firstMatch.exists,
            "Scrolling an installable row must not dispatch its primary download action."
        )
        waitForElementValue(warningRowIdentifier, toEqual: "installable", in: app, timeout: 10)

        tapElementReliably(
            requireElement(warningRowIdentifier, in: app, timeout: 10),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "androidModulePickerDecisionDialogAction::cancel",
            dialogIdentifier: "androidModulePickerDecisionDialog",
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )

        waitForElementValue(warningRowIdentifier, toEqual: "installable", in: app, timeout: 10)

        tapElementReliably(
            requireElement(warningRowIdentifier, in: app, timeout: 10),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "androidModulePickerDecisionDialogAction::install",
            dialogIdentifier: "androidModulePickerDecisionDialog",
            expectedTitle: "OK",
            in: app,
            timeout: 10
        )

        let firstCancel = requireButton(cancelIdentifier, in: app, timeout: 10)
        XCTAssertTrue(requireElement(progressIdentifier, in: app, timeout: 10).exists)
        XCTAssertEqual(awaitDownloadFixtureState(.connected), 1)
        waitForVisiblePartialDownloadProgress(in: app)
        waitForElementValue(warningRowIdentifier, toEqual: "beingInstalled", in: app, timeout: 10)
        assertActiveSessionRowOrder(in: app)
        tapElementReliably(firstCancel, timeout: 10)
        XCTAssertEqual(awaitDownloadFixtureState(.cancelled), 1)
        waitForElementValue(warningRowIdentifier, toEqual: "installable", in: app, timeout: 10)

        tapElementReliably(
            requireElement(warningRowIdentifier, in: app, timeout: 10),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "androidModulePickerDecisionDialogAction::install",
            dialogIdentifier: "androidModulePickerDecisionDialog",
            expectedTitle: "OK",
            in: app,
            timeout: 10
        )
        _ = requireButton(cancelIdentifier, in: app, timeout: 10)
        XCTAssertTrue(requireElement(progressIdentifier, in: app, timeout: 10).exists)
        XCTAssertEqual(awaitDownloadFixtureState(.connected), 2)
        waitForVisiblePartialDownloadProgress(in: app)
        releaseDownloadFixture()
        XCTAssertEqual(awaitDownloadFixtureState(.completed), 2)
        waitForElementValue(warningRowIdentifier, toEqual: "installed", in: app, timeout: 20)
        assertActiveSessionRowOrder(in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(openDownloads(in: app).exists)
        waitForElementValue(warningRowIdentifier, toEqual: "installed", in: app, timeout: 20)
        assertRebuiltInstalledRowOrder(in: app)
    }
}
