import XCTest

extension AndBibleUITests {
    private enum LockedModuleFixture {
        static let single = "UITESTLOCKED"
        static let first = "UITESTLOCKA"
        static let second = "UITESTLOCKB"
        static let key = "rawtextcipherkey"
        static let verse = "Synthetic encrypted first verse."
    }

    /**
     Proves quick-selector lock filtering, the full chooser's real retry loop, decrypted content,
     ordinary toolbar tap after the completed hold route, and persisted-key rekey behavior against
     an actually encrypted RawText module.
     */
    func testLockedBibleIsAbsentFromQuickSelectorAndUnlocksFromFullChooser() {
        let app = makeApp(enablesDetailedAccessibilityExports: false)
        app.launch()
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 20))
        _ = requireElement("readerBibleQuickSelector", in: app, timeout: 10)
        XCTAssertTrue(requireElement("readerBibleQuickSelectorRow_KJV", in: app, timeout: 10).exists)
        XCTAssertFalse(
            unresolvedElement("readerBibleQuickSelectorRow_\(LockedModuleFixture.single)", in: app).exists,
            "A locked Bible must not enter Android's quick readable-document selector."
        )
        tapElementReliably(requireElement("readerBibleQuickSelectorDismissArea", in: app, timeout: 10))

        requireElement("readerBibleToolbarButton", in: app, timeout: 10)
            .press(forDuration: 0.7)
        _ = requireElement("modulePickerScreen", in: app, timeout: 20)
        replaceText(
            in: requireElement("modulePickerSearchField", in: app, timeout: 10),
            with: LockedModuleFixture.single,
            placeholderHints: ["Search"]
        )
        tapElementReliably(
            requireElement("modulePickerRow::\(LockedModuleFixture.single)", in: app, timeout: 15)
        )
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)

        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        tapRetryAction("yes", expectedTitle: "Yes", in: app)
        let field = requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
        field.typeText("wrong-key")
        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        tapRetryAction("yes", expectedTitle: "Yes", in: app)
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
            .typeText(LockedModuleFixture.key)
        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        waitForVisibleReaderText(containing: LockedModuleFixture.verse, in: app, timeout: 20)

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10))
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )
        XCTAssertFalse(
            unresolvedElement("readerBibleQuickSelector", in: app).exists,
            "With exactly two readable Bibles, the post-hold ordinary toolbar tap must switch "
                + "directly from UITESTLOCKED to the distinct KJV content without opening a popup."
        )

        openFullBibleChooser(searching: LockedModuleFixture.single, in: app)
        let unlockedRow = requireElement("modulePickerRow::\(LockedModuleFixture.single)", in: app, timeout: 15)
        unlockedRow.press(forDuration: 0.7)
        tapElementReliably(requireElement("modulePickerContextUnlockButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
        assertPrefilledKey(in: app)
        tapUnlockAction("info", expectedTitle: "Module & unlock info", in: app)
        requireUnlockInformation(in: app)
        tapElementReliably(requireElement("moduleDetailsOKButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
        let afterInformation = assertPrefilledKey(in: app)
        afterInformation.typeText("replacement-after-info")
        XCTAssertEqual(
            afterInformation.value as? String,
            "replacement-after-info",
            "Returning from About must focus and select the restored persisted key before typing."
        )
        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        tapRetryAction("yes", expectedTitle: "Yes", in: app)
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
        let afterRetry = assertPrefilledKey(in: app)
        afterRetry.typeText("replacement-after-retry")
        XCTAssertEqual(
            afterRetry.value as? String,
            "replacement-after-retry",
            "Retry must restore, focus, and select the persisted key before typing."
        )
        tapUnlockAction("cancel", expectedTitle: "Cancel", in: app)
        tapRetryAction("no", expectedTitle: "No", in: app)
        XCTAssertTrue(requireElement("modulePickerScreen", in: app, timeout: 10).exists)
    }

    /**
     Proves Search exposes an installed locked Bible and fails the complete committed selection when
     that source cannot be opened, instead of silently dropping the unavailable translation.
     */
    func testSearchLockedTranslationSelectionFailsExplicitlyWithoutDroppingIt() {
        let app = makeApp()
        app.launch()
        _ = openSearch(in: app)

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(
            in: searchField,
            with: "earth",
            placeholderHints: ["Search Bible text", "Search Bible", "Search"]
        )
        openSearchTranslationPicker(in: app)

        let lockedRow = requireElement(
            "searchTranslationRow::\(javaExactAccessibilitySegment(LockedModuleFixture.single))",
            in: app,
            timeout: 10
        )
        XCTAssertEqual(
            lockedRow.label,
            "UITESTLOCKED - Synthetic Encrypted UI Test Bible (no index)"
        )
        tapElementReliably(lockedRow, timeout: 10)

        let apply = requireElement("searchTranslationPickerApplyButton", in: app, timeout: 10)
        tapElementReliably(apply, timeout: 10)
        waitForSearchSemanticState(
            in: app,
            timeout: 20,
            success: {
                $0.contains("state=indexFailure") &&
                    $0.contains("query=earth") &&
                    $0.contains("UITESTLOCKED")
            },
            failureDescription: {
                "Expected the committed locked translation to produce an explicit index failure; last Search state was '\($0)'."
            }
        )
        XCTAssertTrue(
            app.staticTexts[
                "A selected translation could not be opened for index verification."
            ].firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            unresolvedElement("androidModulePickerUnlockDialog", in: app).exists,
            "Search selection must retain the locked source and use its explicit index failure path."
        )
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "searchResultRow::")
            ).firstMatch.exists,
            "The typed query must not publish partial results after one committed source fails."
        )
    }

    /**
     Proves a real swap-activity Bible tap cycles only through readable installed modules and wraps
     without presenting the credential flow for the retained locked Bible.
     */
    func testSwapActivityBibleNextCyclesReadableModulesAfterInitialKJVPublication() {
        let app = makeApp()
        app.launch()
        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10))
        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTREADABLE",
            in: app,
            timeout: 20
        )
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )
        XCTAssertFalse(unresolvedElement("androidModulePickerUnlockDialog", in: app).exists)

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10))
        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )
    }

    /**
     Proves a real commentary-to-Bible swap retains the pane's exact locked Bible suggestion and
     uses the shared credential flow before switching, without substituting a readable Bible.
     */
    func testSwapActivityFromCommentaryUnlocksExactRetainedBibleSuggestion() {
        let app = makeApp()
        app.launch()
        waitForReaderRenderedContentState(
            containing: "category=commentary;module=000UITestComm",
            in: app,
            timeout: 20
        )
        waitForVisibleReaderText(
            containing: "No content for selected verse",
            in: app,
            timeout: 20
        )
        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
            .typeText(LockedModuleFixture.key)
        tapUnlockAction("okay", expectedTitle: "OK", in: app)

        waitForVisibleReaderText(containing: LockedModuleFixture.verse, in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "category=bible;module=UITESTLOCKED",
            in: app,
            timeout: 20
        )
    }

    /**
     Proves Downloads' actual contextual Unlock action shares About, retry, manager persistence, and
     decrypted reader behavior without invoking the download/install path.
     */
    func testDownloadsUnlockRetriesSameRealModuleAndMakesContentReadable() {
        let app = makeApp(enablesDetailedAccessibilityExports: false)
        app.launch()
        XCTAssertTrue(openDownloads(in: app).exists)
        let search = requireElement("moduleBrowserSearchField", in: app, timeout: 10)
        replaceText(in: search, with: LockedModuleFixture.single, placeholderHints: ["Search"])
        let rowID = "moduleBrowserRow::UITest Locked--\(LockedModuleFixture.single)"
        let row = requireElement(rowID, in: app, timeout: 15)
        row.press(forDuration: 0.7)
        tapElementReliably(requireElement("moduleBrowserContextUnlockButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)

        tapUnlockAction("info", expectedTitle: "Module & unlock info", in: app)
        requireUnlockInformation(in: app)
        tapElementReliably(requireElement("moduleDetailsOKButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
            .typeText("wrong-key")
        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        tapRetryAction("yes", expectedTitle: "Yes", in: app)
        requireUnlockPassphraseField(in: app)
            .typeText(LockedModuleFixture.key)
        tapUnlockAction("okay", expectedTitle: "OK", in: app)
        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 15).exists)

        let unlockedRow = requireElement(rowID, in: app, timeout: 15)
        unlockedRow.press(forDuration: 0.7)
        tapElementReliably(requireElement("moduleBrowserContextUnlockButton", in: app, timeout: 10))
        requireUnlockPrompt(for: LockedModuleFixture.single, in: app)
        assertPrefilledKey(in: app)
        tapUnlockAction("cancel", expectedTitle: "Cancel", in: app)
        tapRetryAction("no", expectedTitle: "No", in: app)
        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("moduleBrowserBackButton", in: app, timeout: 10))
        openFullBibleChooser(searching: LockedModuleFixture.single, in: app)
        tapElementReliably(
            requireElement("modulePickerRow::\(LockedModuleFixture.single)", in: app, timeout: 15)
        )
        waitForVisibleReaderText(containing: LockedModuleFixture.verse, in: app, timeout: 20)
    }

    /**
     Accepts the first real locked-only Bible, proves the second prompt remains queued, declines the
     second, then verifies durable startup suppression and the still-locked second row after relaunch.
     */
    func testLockedOnlyStartupProcessesRealEncryptedBiblesInInstalledOrder() {
        let app = makeApp(enablesDetailedAccessibilityExports: false)
        app.launch()
        _ = requireElement("startupLockedBibleUnlockQueue", in: app, timeout: 15)
        requireUnlockPrompt(for: LockedModuleFixture.first, in: app)
            .typeText(LockedModuleFixture.key)
        tapUnlockAction("okay", expectedTitle: "OK", in: app)

        requireUnlockPrompt(for: LockedModuleFixture.second, in: app)
        XCTAssertTrue(requireElement("startupLockedBibleUnlockQueue", in: app, timeout: 10).exists)
        tapUnlockAction("cancel", expectedTitle: "Cancel", in: app)
        tapRetryAction("no", expectedTitle: "No", in: app)
        waitForVisibleReaderText(containing: LockedModuleFixture.verse, in: app, timeout: 20)

        app.terminate()
        app.launch()
        waitForVisibleReaderText(containing: LockedModuleFixture.verse, in: app, timeout: 20)
        XCTAssertFalse(
            unresolvedElement("startupLockedBibleUnlockQueue", in: app).exists,
            "A readable first Bible must suppress the locked-only startup queue on relaunch."
        )

        openFullBibleChooser(searching: LockedModuleFixture.second, in: app)
        tapElementReliably(
            requireElement("modulePickerRow::\(LockedModuleFixture.second)", in: app, timeout: 15)
        )
        requireUnlockPrompt(for: LockedModuleFixture.second, in: app)
        tapUnlockAction("cancel", expectedTitle: "Cancel", in: app)
        tapRetryAction("no", expectedTitle: "No", in: app)
    }

    /** Opens the production full chooser and narrows its real search field to one module identity. */
    private func openFullBibleChooser(searching initials: String, in app: XCUIApplication) {
        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        _ = requireElement("modulePickerScreen", in: app, timeout: 20)
        let search = requireElement("modulePickerSearchField", in: app, timeout: 10)
        replaceText(in: search, with: initials, placeholderHints: ["Search"])
    }

    /** Opens the visible Search translation picker after its autofocus viewport has settled. */
    private func openSearchTranslationPicker(in app: XCUIApplication) {
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
        XCTAssertTrue(
            requireElement("searchTranslationPickerDialog", in: app, timeout: 10).exists
        )
    }

    /** Encodes an exact Java string identity into Search's public row-identifier segment. */
    private func javaExactAccessibilitySegment(_ value: String) -> String {
        let units = Array(value.utf16)
        guard !units.isEmpty else { return "empty" }
        return units.map { String(format: "%04X", $0) }.joined(separator: "-")
    }

    /** Requires the exact visible module title, input, and public actions for one unlock prompt. */
    @discardableResult
    private func requireUnlockPrompt(for initials: String, in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(
            app.staticTexts[
                "Document \(initials) is encrypted and needs passphrase to be unlocked"
            ].firstMatch.waitForExistence(timeout: 10)
        )
        let field = requireUnlockPassphraseField(in: app)
        XCTAssertTrue(
            exactButton(
                identifier: "androidModulePickerUnlockDialogAction::info",
                in: app
            ).waitForExistence(timeout: 10)
        )
        let okay = exactButton(
            identifier: "androidModulePickerUnlockDialogAction::okay",
            in: app
        )
        XCTAssertTrue(okay.waitForExistence(timeout: 10))
        XCTAssertTrue(okay.isEnabled)
        return field
    }

    /** Requires the exact UIKit text-field surface exposed by the shared unlock editor. */
    private func requireUnlockPassphraseField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let field = app.textFields["androidModulePickerUnlockDialogPassphrase"].firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: timeout),
            "Expected the unlock passphrase TextField to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return field
    }

    /** Requires the real persisted key and returns the untouched, automatically focused field. */
    private func assertPrefilledKey(in app: XCUIApplication) -> XCUIElement {
        let field = requireUnlockPassphraseField(in: app)
        XCTAssertEqual(field.value as? String, LockedModuleFixture.key)
        return field
    }

    /** Requires independent visible lines from the shared rich-text unlock information dialog. */
    private func requireUnlockInformation(in app: XCUIApplication) {
        let messageLines = app.staticTexts.matching(identifier: "moduleDetailsDialogMessage")
        for expectedLabel in [
            "Synthetic Encrypted UI Test Bible",
            "Real encrypted UI fixture metadata for UITESTLOCKED.",
            "OSIS ID: UITESTLOCKED",
        ] {
            let line = messageLines.matching(
                NSPredicate(format: "label == %@", expectedLabel)
            ).firstMatch
            XCTAssertTrue(
                line.waitForExistence(timeout: 10),
                "Expected visible unlock information line '\(expectedLabel)'."
            )
        }
    }

    /** Taps one exact action inside the app-owned passphrase dialog. */
    private func tapUnlockAction(_ id: String, expectedTitle: String, in app: XCUIApplication) {
        let action = exactButton(
            identifier: "androidModulePickerUnlockDialogAction::\(id)",
            in: app
        )
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertEqual(action.label, expectedTitle)
        XCTAssertTrue(action.isEnabled)
        tapElementReliably(action, timeout: 10)
    }

    /** Taps one exact action inside the shared retry decision. */
    private func tapRetryAction(_ id: String, expectedTitle: String, in app: XCUIApplication) {
        let identifier = "androidModulePickerDecisionDialogAction::\(id)"
        let keyboard = app.keyboards.firstMatch
        var previousFrame: CGRect?
        var settledAction: XCUIElement?
        let didSettle = waitForUITestCondition(
            "Retry action settles after keyboard dismissal",
            timeout: 10
        ) {
            guard !keyboard.exists else {
                previousFrame = nil
                return false
            }
            let action = self.exactButton(identifier: identifier, in: app)
            guard action.exists,
                  action.label == expectedTitle,
                  action.isEnabled,
                  self.isElementHittable(action) else {
                previousFrame = nil
                return false
            }
            let currentFrame = action.frame
            defer { previousFrame = currentFrame }
            guard previousFrame == currentFrame else { return false }
            settledAction = action
            return true
        }
        XCTAssertTrue(
            didSettle,
            "Expected retry action '\(expectedTitle)' to settle after keyboard dismissal."
        )
        guard let action = settledAction else { return }
        XCTAssertEqual(action.label, expectedTitle)
        XCTAssertTrue(action.isEnabled)
        tapElementReliably(action, timeout: 10)
    }

    /**
     Resolves one app-owned dialog button using XCTest's public exact-identifier predicate API.

     This intentionally limits the selector experiment to controls whose identifiers are owned by
     the test target. The returned element preserves existing existence, label, enabled, frame, and
     hittability checks; it performs no retries and does not weaken any assertion.
     */
    private func exactButton(identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }
}
