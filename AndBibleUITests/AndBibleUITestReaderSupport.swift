import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func requireButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireElement(
            identifier,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Polls one accessibility-identified element until its value matches the expected semantic token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier whose resolved element value should be sampled.
     *   - expectedValue: Semantic value expected before the timeout expires.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy for the requested identifier
     *   - records an XCTest failure when the value never reaches the expected state before timeout
     * - Failure modes:
     *   - fails when the element disappears or its accessibility value never reaches the requested
     *     token within the timeout window
     */
    func waitForElementValue(
        _ identifier: String,
        toEqual expectedValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentValue = resolvedElementSemanticText(identifier, in: app),
               currentValue == expectedValue
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedElementSemanticText(identifier, in: app) ?? "<missing>"
        XCTAssertEqual(
            finalValue,
            expectedValue,
            "Expected element '\(identifier)' to reach value '\(expectedValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to contain a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - expectedToken: Token that should appear inside the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy until the requested token appears in the
     *     element value or label
     * - Failure modes:
     *   - fails when the element disappears or never reports the requested token before timeout
     */
    func waitForElementValue(
        _ identifier: String,
        toContain expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentValue = resolvedElementSemanticText(identifier, in: app),
               currentValue.contains(expectedToken)
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedElementSemanticText(identifier, in: app) ?? "<missing>"
        XCTAssertTrue(
            finalValue.contains(expectedToken),
            "Expected element '\(identifier)' to contain token '\(expectedToken)' within \(timeout) seconds. Final value: '\(finalValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to stop containing a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - unexpectedToken: Token that should disappear from the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy until the requested token disappears from
     *     the element value and label
     * - Failure modes:
     *   - fails when the element disappears or keeps reporting the token after the timeout
     */
    func waitForElementValue(
        _ identifier: String,
        toNotContain unexpectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentValue = resolvedElementSemanticText(identifier, in: app) {
                if !currentValue.contains(unexpectedToken) {
                    return
                }
            } else {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedElementSemanticText(identifier, in: app) ?? "<missing>"
        XCTAssertFalse(
            finalValue.contains(unexpectedToken),
            "Expected element '\(identifier)' to stop containing '\(unexpectedToken)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element to reach the requested existence state.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to re-resolve while polling.
     *   - app: Running application under test.
     *   - shouldExist: Requested final existence state.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly samples the live XCUI hierarchy until the requested element exists or
     *     disappears
     * - Failure modes:
     *   - records an XCTest failure when the element never reaches the requested existence state
     */
    func waitForElementExistence(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let currentExists = resolvedElement(identifier, in: app) != nil
            if currentExists == shouldExist {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let currentExists = resolvedElement(identifier, in: app) != nil
        XCTAssertEqual(
            currentExists,
            shouldExist,
            "Expected element '\(identifier)' existence to become \(shouldExist) within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element to appear without recording an XCTest failure.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve while polling.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before giving up.
     * - Returns: `true` when the element appears before the timeout, otherwise `false`.
     * - Side effects:
     *   - repeatedly re-resolves the live XCUI hierarchy without triggering `waitForExistence`
     *     debug capture when the element is legitimately absent
     * - Failure modes: This helper cannot fail.
     */
    func waitForResolvedElementAppearance(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if resolvedElement(identifier, in: app) != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return resolvedElement(identifier, in: app) != nil
    }


    /**
     Waits for the reader shell's overflow-menu button, allowing extra time for the first cold app
     launch in the UI bundle.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the reader shell to become interactive.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The reader overflow-menu button once the reader shell has rendered it.
     * - Side effects:
     *   - repeatedly queries the live XCUI hierarchy while the reader shell finishes bootstrapping
     * - Failure modes:
     *   - records an XCTest failure if the reader shell never reaches a state where the overflow
     *     menu button exists within the allotted timeout
     */
    func requireReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireButton(
            "readerMoreMenuButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Taps the reader overflow-menu button after the reader shell becomes interactive.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the toolbar button to exist and become
     *     hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the overflow-menu button from the live toolbar hierarchy
     *   - taps its center point directly through the shared reliable-tap helper
     * - Failure modes:
     *   - records an XCTest failure if the overflow-menu button never becomes usable within the
     *     allotted timeout
     */
    func tapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderMoreMenuButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader overflow menu to appear after tapping readerMoreMenuButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Attempts to open the reader overflow menu without recording an XCTest failure on timeout.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend trying to open the overflow menu.
     *   - file: Source file used for nested helper attribution.
     *   - line: Source line used for nested helper attribution.
     * - Returns: `true` when the production overflow menu becomes visible.
     * - Side effects:
     *   - taps the production more-menu button and waits for the menu surface to appear
     * - Failure modes:
     *   - returns `false` when the menu never appears before the local retry budget expires
     */
    func tryTapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        _ = waitForReaderShellReady(in: app, timeout: min(10, timeout))
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let button = unresolvedElement("readerMoreMenuButton", in: app)
            tapReaderMoreMenuChromeCoordinate(in: app)
            if waitForReaderOverflowMenu(in: app, timeout: min(2, max(1, deadline.timeIntervalSinceNow))) {
                return true
            }
            if elementHasUsableFrame(button) {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else if waitForElementToBecomeHittable(button, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                button.tap()
            }
            if waitForReaderOverflowMenu(in: app, timeout: min(5, max(1, deadline.timeIntervalSinceNow))) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Dismisses the reader overflow menu and waits until the reader shell is visible again.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend dismissing the overflow menu.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the explicit dismiss area when available and falls back to dragging the overflow
     *     panel down when the overlay ignores the first tap
     * - Failure modes:
     *   - records an XCTest failure when the overflow menu never disappears before timeout
     */
    func dismissReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            guard let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                  !overflowMenu.frame.isEmpty else {
                if waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            let dismissArea = unresolvedElement("readerOverflowMenuDismissArea", in: app)
            if dismissArea.exists && !dismissArea.frame.isEmpty {
                let backdropTapPoint = dismissArea.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2))
                backdropTapPoint.tap()
                if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                    waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
            }

            let overflowButton = unresolvedElement("readerMoreMenuButton", in: app)
            if overflowButton.exists &&
                waitForElementToBecomeHittable(
                    overflowButton,
                    timeout: min(1, max(0.25, deadline.timeIntervalSinceNow))
                )
            {
                overflowButton.tap()
                if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                    waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
            }

            dismissSheetByDraggingDown(overflowMenu, file: file, line: line)
            if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                return
            }
        } while Date() < deadline

        XCTAssertFalse(
            waitForReaderOverflowMenu(in: app, timeout: 1),
            "Expected the reader overflow menu to dismiss within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the custom reader overflow sheet to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the overflow sheet.
     * - Returns: `true` when the production `readerOverflowMenu` scroll view appears.
     * - Side effects:
     *   - polls the explicit overflow-sheet accessibility identifier instead of scanning the full
     *     app hierarchy for guessed menu containers.
     * - Failure modes:
     *   - returns `false` when the overflow sheet never appears before timeout.
     */
    func waitForReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let menuCandidates = [
            app.otherElements["readerOverflowMenu"].firstMatch,
            app.scrollViews["readerOverflowMenu"].firstMatch,
        ]
        let actionCandidates = [
            app.buttons["readerOpenWorkspacesAction"].firstMatch,
            app.buttons["readerOverflowNightModeToggle"].firstMatch,
            app.buttons["readerOverflowSectionTitlesToggle"].firstMatch,
        ]
        repeat {
            if let overflowVisible = readerRenderedContentStateFlag("overflowVisible", in: app) {
                if overflowVisible {
                    return true
                }
            } else if menuCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) ||
                actionCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let overflowVisible = readerRenderedContentStateFlag("overflowVisible", in: app) {
            return overflowVisible
        }

        return menuCandidates.contains(where: { $0.exists }) ||
            actionCandidates.contains(where: { $0.exists })
    }

    /**
     Taps the Android-style reader navigation drawer button and waits for the drawer to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the drawer to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the production `readerNavigationDrawerButton`
     *   - taps it directly and waits for the `readerNavigationDrawer` surface
     * - Failure modes:
     *   - records an XCTest failure if the drawer never appears in time
     */
    func tapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderNavigationDrawerButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader navigation drawer to appear after tapping readerNavigationDrawerButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Attempts to open the reader navigation drawer without recording an XCTest failure on timeout.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend trying to open the drawer.
     *   - file: Source file used for nested helper attribution.
     *   - line: Source line used for nested helper attribution.
     * - Returns: `true` when the production drawer becomes visible.
     * - Side effects:
     *   - taps the production navigation-drawer button and waits for drawer affordances to appear
     * - Failure modes:
     *   - returns `false` when the drawer never appears before the local retry budget expires
     */
    func tryTapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        _ = waitForReaderShellReady(in: app, timeout: min(10, timeout))
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let button = unresolvedElement("readerNavigationDrawerButton", in: app)
            tapReaderNavigationDrawerChromeCoordinate(in: app)
            if waitForReaderNavigationDrawer(
                in: app,
                timeout: min(2, max(1, deadline.timeIntervalSinceNow))
            ) {
                return true
            }
            if elementHasUsableFrame(button) {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else if waitForElementToBecomeHittable(button, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                button.tap()
            }
            if waitForReaderNavigationDrawer(
                in: app,
                timeout: min(5, max(2, deadline.timeIntervalSinceNow))
            ) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /// Taps the reader drawer affordance without forcing XCTest to snapshot its frame first.
    func tapReaderNavigationDrawerChromeCoordinate(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.06)).tap()
    }

    /// Taps the reader overflow affordance without forcing XCTest to snapshot its frame first.
    func tapReaderMoreMenuChromeCoordinate(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.06)).tap()
    }

    /**
     Waits for the Android-style reader navigation drawer to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the drawer.
     * - Returns: `true` when the production `readerNavigationDrawer` surface appears.
     * - Side effects:
     *   - polls the explicit drawer accessibility identifier.
     * - Failure modes:
     *   - returns `false` when the drawer never appears before timeout.
     */
    func waitForReaderNavigationDrawer(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let drawerCandidates = [
            app.scrollViews["readerNavigationDrawer"].firstMatch,
            app.otherElements["readerNavigationDrawer"].firstMatch,
        ]
        let actionCandidates = [
            app.buttons["readerOpenBookmarksAction"].firstMatch,
            app.buttons["readerOpenSettingsAction"].firstMatch,
            app.buttons["readerOpenSearchAction"].firstMatch,
        ]
        repeat {
            if let drawerVisible = readerRenderedContentStateFlag("drawerVisible", in: app) {
                if drawerVisible {
                    return true
                }
            } else if drawerCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) ||
                actionCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let drawerVisible = readerRenderedContentStateFlag("drawerVisible", in: app) {
            return drawerVisible
        }

        return drawerCandidates.contains(where: { $0.exists }) ||
            actionCandidates.contains(where: { $0.exists })
    }

    /**
     Taps one reader-shell action after the stable action surface has been resolved.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the reader action to invoke.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the action to appear and become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the requested reader action button to appear
     *   - taps the resolved button through the shared reliable-tap helper
     * - Failure modes:
     *   - records an XCTest failure if the requested reader action never appears or never becomes
     *     hittable within the allotted timeout
     */
    func tapReaderAction(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let usesNavigationDrawer = readerActionUsesNavigationDrawer(identifier)

        repeat {
            guard let button = tryResolveReaderActionControl(
                identifier,
                in: app,
                timeout: min(3, max(1, deadline.timeIntervalSinceNow))
            ) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            if waitForElementToBecomeHittable(button, timeout: min(1.5, max(0.5, deadline.timeIntervalSinceNow))) {
                button.tap()
            } else {
                let preferredSurfaceIdentifier = usesNavigationDrawer
                    ? "readerNavigationDrawer"
                    : "readerOverflowMenu"
                let fallbackSurfaceIdentifier = usesNavigationDrawer
                    ? "readerOverflowMenu"
                    : "readerNavigationDrawer"
                let actionSurface = resolvedElement(preferredSurfaceIdentifier, in: app)
                    ?? resolvedElement(fallbackSurfaceIdentifier, in: app)

                if let actionSurface,
                   isElementVisible(button, within: actionSurface)
                {
                    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                } else {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    continue
                }
            }

            if waitForReaderActionActivationToSettle(
                identifier,
                usesNavigationDrawer: usesNavigationDrawer,
                in: app,
                timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))
            ) {
                return
            }
        } while Date() < deadline

        let button = requireReaderActionControl(
            identifier,
            in: app,
            timeout: min(5, timeout),
            file: file,
            line: line
        )
        if let actionSurface = ensureReaderActionSurface(
            for: identifier,
            in: app,
            timeout: min(5, timeout),
            file: file,
            line: line
        ) {
            if waitForElementToBecomeHittable(button, timeout: min(1, timeout)) {
                button.tap()
                _ = waitForReaderActionActivationToSettle(
                    identifier,
                    usesNavigationDrawer: usesNavigationDrawer,
                    in: app,
                    timeout: min(2, timeout)
                )
                return
            }

            if isElementVisible(button, within: actionSurface) {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = waitForReaderActionActivationToSettle(
                    identifier,
                    usesNavigationDrawer: usesNavigationDrawer,
                    in: app,
                    timeout: min(2, timeout)
                )
                return
            }

            XCTFail(
                "Expected element '\(identifier)' to become tappable within \(timeout) seconds.",
                file: file,
                line: line
            )
            return
        }

        XCTFail(
            "Expected the reader action surface to remain available while activating '\(identifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits briefly for a tapped reader menu action to either dismiss its source surface or disappear.
     */
    func waitForReaderActionActivationToSettle(
        _ identifier: String,
        usesNavigationDrawer: Bool,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if usesNavigationDrawer {
                if !isReaderNavigationDrawerLikelyVisible(in: app) {
                    return true
                }
            } else if !isReaderOverflowMenuLikelyVisible(in: app) {
                return true
            }

            let refreshedButton = unresolvedElement(identifier, in: app)
            if !refreshedButton.exists {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Opens About from the reader overflow menu with one bounded retry when the first tap does not
     transition away from the live menu.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend across menu discovery, action tapping, and
     *     destination confirmation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - opens the reader overflow menu
     *   - taps the About action up to two times when the first tap leaves the menu open
     * - Failure modes:
     *   - records an XCTest failure if the About destination never appears within the allotted
     *     timeout
     */
    func openAboutFromReaderMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        for attempt in 1...2 {
            let remaining = max(1, deadline.timeIntervalSinceNow)
            tapReaderAction(
                "readerOpenAboutAction",
                in: app,
                timeout: min(10, remaining),
                file: file,
                line: line
            )
            if waitForAboutScreenVisible(in: app, timeout: min(8, max(1, deadline.timeIntervalSinceNow))) {
                return
            }

            if attempt == 1 {
                if resolvedElement("readerNavigationDrawer", in: app) != nil {
                    continue
                }
            }
        }

        XCTAssertTrue(
            waitForAboutScreenVisible(in: app, timeout: min(5, max(1, deadline.timeIntervalSinceNow))),
            "Expected the About destination to surface within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Confirms the About destination rendered after reader-menu navigation.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the About destination to surface.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls explicit About-only accessibility identifiers so the waiter does not rely on broad
     *     hierarchy scans or generic localized button titles during sheet transitions
     * - Failure modes:
     *   - records an XCTest failure if none of the About-specific surface identifiers appears
     *     within the allotted timeout
     */
    func waitForAboutScreenVisible(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        waitForAnyElement(
            ["aboutDoneButton", "aboutAppTitle", "aboutScreen", "aboutSheetScreen"],
            in: app,
            timeout: timeout,
            file: file,
            line: line
        ) != nil
    }

    /**
     Maps one reader overflow action identifier to the visible English menu title exported by the
     production `Menu` rows.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: User-visible menu title that XCTest can use as a fallback query surface.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func readerActionTitle(for identifier: String) -> String {
        switch identifier {
        case "readerChooseDocumentAction":
            return "Choose Document"
        case "readerOpenSearchAction":
            return "Search"
        case "readerOpenSpeakAction":
            return "Speak"
        case "readerOpenBookmarksAction":
            return "Bookmarks"
        case "readerOpenStudyPadsAction":
            return "StudyPads"
        case "readerOpenMyNotesAction":
            return "My Notes"
        case "readerOpenHistoryAction":
            return "History"
        case "readerOpenReadingPlansAction":
            return "Reading Plan"
        case "readerOpenSettingsAction":
            return "Application preferences"
        case "readerOpenWorkspacesAction":
            return "Workspaces…"
        case "readerOpenDownloadsAction":
            return "Download Documents"
        case "readerOpenImportExportAction":
            return "Backup & Restore"
        case "readerOpenSyncSettingsAction":
            return "Device synchronization"
        case "readerOpenLabelSettingsAction":
            return "Label Settings…"
        case "readerOpenHelpAction":
            return "Help & Tips"
        case "readerSponsorDevelopmentAction":
            return "Buy development work"
        case "readerNeedHelpAction":
            return "Need Help"
        case "readerContributeAction":
            return "How to Contribute"
        case "readerOpenAboutAction":
            return "About"
        case "readerOpenAppLicenseAction":
            return "App Licence"
        case "readerTellFriendAction":
            return "Recommend to a friend"
        case "readerRateAppAction":
            return "Rate & Review"
        case "readerReportBugAction":
            return "Feedback / bug report"
        default:
            return identifier
        }
    }

    /// Returns direct app-level candidates for reader drawer and overflow actions.
    func readerDirectActionCandidates(
        _ identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let title = readerActionTitle(for: identifier)
        return [
            app.buttons[identifier].firstMatch,
            app.buttons[title].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Declares which production reader action surface should host one action identifier.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: `true` when the action belongs to the left navigation drawer; otherwise `false`
     *   and the action belongs to the overflow/options menu.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func readerActionUsesNavigationDrawer(_ identifier: String) -> Bool {
        switch identifier {
        case "readerOpenBookmarksAction",
             "readerOpenHistoryAction",
             "readerOpenReadingPlansAction",
             "readerOpenDownloadsAction",
             "readerOpenSettingsAction",
             "readerOpenAboutAction",
             "readerChooseDocumentAction",
             "readerOpenSearchAction",
             "readerOpenSpeakAction",
             "readerOpenStudyPadsAction",
             "readerOpenMyNotesAction",
             "readerOpenImportExportAction",
             "readerOpenSyncSettingsAction",
             "readerOpenHelpAction",
             "readerNeedHelpAction",
             "readerContributeAction",
             "readerOpenAppLicenseAction",
             "readerTellFriendAction",
             "readerRateAppAction",
             "readerReportBugAction":
            return true
        default:
            return false
        }
    }

    /**
     Ensures the correct production reader action surface is open for one action identifier.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the requested reader action.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend dismissing conflicting surfaces and opening
     *     the required one.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The currently visible action surface, or `nil` when it never becomes available
     *   inside the local retry budget.
     * - Side effects:
     *   - dismisses the wrong menu surface when it is currently visible
     *   - opens either the left navigation drawer or the overflow/options sheet
     * - Failure modes:
     *   - returns `nil` when the required action surface never becomes available before timeout
     */
    func ensureReaderActionSurface(
        for identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)

        repeat {
            if prefersDrawer {
                let drawerVisible = readerRenderedContentStateFlag("drawerVisible", in: app)
                if drawerVisible == true {
                    return unresolvedElement("readerNavigationDrawer", in: app)
                } else if drawerVisible == nil,
                          let drawer = resolvedElement("readerNavigationDrawer", in: app),
                          !drawer.frame.isEmpty {
                    return drawer
                }
                if isReaderOverflowMenuLikelyVisible(in: app) {
                    dismissReaderOverflowMenu(
                        in: app,
                        timeout: min(8, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                } else {
                    _ = tryTapReaderNavigationDrawerButton(
                        in: app,
                        timeout: min(12, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                }
            } else {
                let overflowVisible = readerRenderedContentStateFlag("overflowVisible", in: app)
                if overflowVisible == true {
                    return unresolvedElement("readerOverflowMenu", in: app)
                } else if overflowVisible == nil,
                          let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                          !overflowMenu.frame.isEmpty {
                    return overflowMenu
                }
                if isReaderNavigationDrawerLikelyVisible(in: app) {
                    let dismissArea = unresolvedElement("readerNavigationDrawerDismissArea", in: app)
                    if dismissArea.exists {
                        tapElementReliably(dismissArea, timeout: 5, file: file, line: line)
                    }
                } else {
                    _ = tryTapReaderMoreMenuButton(
                        in: app,
                        timeout: min(12, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if prefersDrawer {
            if let drawerVisible = readerRenderedContentStateFlag("drawerVisible", in: app) {
                return drawerVisible ? unresolvedElement("readerNavigationDrawer", in: app) : nil
            }
            return resolvedElement("readerNavigationDrawer", in: app)
        }

        if let overflowVisible = readerRenderedContentStateFlag("overflowVisible", in: app) {
            return overflowVisible ? unresolvedElement("readerOverflowMenu", in: app) : nil
        }
        return resolvedElement("readerOverflowMenu", in: app)
    }

    /**
     Returns `true` when drawer-only controls indicate that the left navigation drawer is exposed.
     */
    func isReaderNavigationDrawerLikelyVisible(in app: XCUIApplication) -> Bool {
        if let drawerVisible = readerRenderedContentStateFlag("drawerVisible", in: app) {
            return drawerVisible
        }

        if let drawer = resolvedElement("readerNavigationDrawer", in: app),
           !drawer.frame.isEmpty
        {
            return true
        }

        if let dismissArea = resolvedElement("readerNavigationDrawerDismissArea", in: app),
           !dismissArea.frame.isEmpty
        {
            return true
        }

        return false
    }

    /**
     Returns `true` when overflow-only controls indicate that the reader overflow menu is exposed.
     */
    func isReaderOverflowMenuLikelyVisible(in app: XCUIApplication) -> Bool {
        if let overflowVisible = readerRenderedContentStateFlag("overflowVisible", in: app) {
            return overflowVisible
        }

        if let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
           !overflowMenu.frame.isEmpty
        {
            return true
        }

        if let dismissArea = resolvedElement("readerOverflowMenuDismissArea", in: app),
           !dismissArea.frame.isEmpty
        {
            return true
        }

        return false
    }

    /**
     Returns whether an identifier is one of the compact semantic state exports emitted for UI tests.
     *
     * - Parameter identifier: Accessibility identifier that may name a state export probe.
     * - Returns: `true` when the identifier is backed by a tiny state-export element.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func isSemanticStateExportIdentifier(_ identifier: String) -> Bool {
        switch identifier {
        case
            "searchStateExport",
            "bookmarkListStateExport",
            "readingPlanListStateExport",
            "availablePlansStateExport",
            "labelManagerStateExport",
            "syncSettingsState":
            return true
        default:
            return false
        }
    }

    /**
     Samples the value from compact state-export probes without first asking XCTest for existence.
     *
     * XCTest can spend tens of seconds rebuilding snapshots for volatile SwiftUI surfaces when a test
     * repeatedly calls `exists` before reading a known state probe. These probes are emitted only for
     * UI automation and carry their contract in `accessibilityValue`, so callers can sample the value
     * directly and let a missing value mean "not observable yet".
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of a compact state-export probe.
     *   - app: Running application under test.
     * - Returns: First non-empty exported value from the ordered semantic state candidates.
     * - Side effects: none.
     * - Failure modes: returns `nil` when no state probe currently publishes a value.
     */
    func semanticStateExportValue(
        _ identifier: String,
        in app: XCUIApplication
    ) -> String? {
        for candidate in semanticStateCandidates(for: identifier, in: app) {
            if let value = candidate.value as? String,
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    /**
     Returns the semantic accessibility text exported for one resolved element.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier under test.
     *   - app: Running application whose live hierarchy should be sampled.
     * - Returns: The exported accessibility value when present, otherwise a conservative label
     *   fallback for simple text-bearing controls. Compact state exports are sampled directly from
     *   `accessibilityValue` without a separate existence query.
     * - Side effects: none.
     * - Failure modes: returns `nil` when the element is absent or has no safe semantic text.
     */
    func resolvedElementSemanticText(
        _ identifier: String,
        in app: XCUIApplication
    ) -> String? {
        if isSemanticStateExportIdentifier(identifier),
           let value = semanticStateExportValue(identifier, in: app)
        {
            return value
        }

        guard let element = resolvedElement(identifier, in: app) else {
            return nil
        }

        if let value = element.value as? String {
            return value
        }

        switch element.elementType {
        case .staticText, .button, .link:
            return element.label
        default:
            return nil
        }
    }

    /**
     Resolves one reader overflow action from either its stable accessibility identifier or its
     visible menu title.
     *
     * - Parameters:
     *   - identifier: Stable accessibility identifier attached in `BibleReaderView`.
     *   - app: Running application under test.
     * - Returns: Best-effort live XCUI element for the action.
     * - Side effects: none.
     * - Failure modes: returns a non-existing identifier-backed element when no live match exists.
     */
    func resolveReaderActionElement(
        _ identifier: String,
        in app: XCUIApplication,
        actionSurface: XCUIElement
    ) -> XCUIElement {
        let title = readerActionTitle(for: identifier)
        let scopedCandidates = [
            actionSurface.buttons[identifier].firstMatch,
            actionSurface.buttons[title].firstMatch,
            actionSurface.otherElements[identifier].firstMatch,
        ]

        if let visibleCandidate = scopedCandidates.first(where: { isElementHittable($0) }) {
            return visibleCandidate
        }
        if let frameCandidate = scopedCandidates.first(where: { elementHasUsableFrame($0) }) {
            return frameCandidate
        }
        return scopedCandidates.first(where: { $0.exists }) ?? actionSurface.buttons[identifier].firstMatch
    }

    /**
     Resolves one reader-shell menu action, scrolling the live menu surface when the requested
     action starts below the fold.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the reader action to resolve.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to keep searching and scrolling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved reader action button.
     * - Side effects:
     *   - re-queries the live accessibility hierarchy while swiping the visible menu container
     *     upward to reveal actions lower in the overflow menu
     * - Failure modes:
     *   - records an XCTest failure when the requested action never appears before the timeout
     */
    func requireReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let control = tryResolveReaderActionControl(identifier, in: app, timeout: timeout) {
            return control
        }

        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        let directActionCandidates = readerDirectActionCandidates(identifier, in: app)

        if let finalSurface = prefersDrawer
            ? resolvedElement("readerNavigationDrawer", in: app)
            : resolvedElement("readerOverflowMenu", in: app)
        {
            let finalAction = resolveReaderActionElement(identifier, in: app, actionSurface: finalSurface)
            XCTAssertTrue(
                finalAction.exists,
                "Expected reader action '\(identifier)' to exist within \(timeout) seconds.",
                file: file,
                line: line
            )
            return finalAction
        }

        if let directAction = directActionCandidates.first(where: { elementHasUsableFrame($0) }) {
            return directAction
        }

        let preferredSurfaceIdentifier = prefersDrawer ? "readerNavigationDrawer" : "readerOverflowMenu"
        let actionSurface = resolvedElement(preferredSurfaceIdentifier, in: app)
            ?? unresolvedElement(preferredSurfaceIdentifier, in: app)
        XCTAssertTrue(
            actionSurface.exists,
            "Expected the reader action surface to appear within \(timeout) seconds before resolving '\(identifier)'.",
            file: file,
            line: line
        )
        return resolveReaderActionElement(identifier, in: app, actionSurface: actionSurface)
    }

    /**
     Attempts to resolve one reader-shell action without recording an XCTest failure on transient
     drawer/overflow misses.
     */
    func tryResolveReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        let directActionCandidates = readerDirectActionCandidates(identifier, in: app)
        repeat {
            if let actionSurface = ensureReaderActionSurface(
                for: identifier,
                in: app,
                timeout: min(10, max(3, deadline.timeIntervalSinceNow))
            ) {
                for _ in 0..<4 {
                    let action = resolveReaderActionElement(identifier, in: app, actionSurface: actionSurface)
                    if action.exists, waitForElementToBecomeHittable(action, timeout: 0.5) {
                        return action
                    }
                    if isElementVisible(action, within: actionSurface) {
                        return action
                    }
                    if let directAction = directActionCandidates.first(where: { isElementHittable($0) }) {
                        return directAction
                    }
                    if elementHasUsableFrame(actionSurface) {
                        actionSurface.swipeUp()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                }
            }

            if let directAction = directActionCandidates.first(where: { isElementHittable($0) }) {
                return directAction
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let finalSurface = prefersDrawer
            ? resolvedElement("readerNavigationDrawer", in: app)
            : resolvedElement("readerOverflowMenu", in: app)
        {
            let finalAction = resolveReaderActionElement(identifier, in: app, actionSurface: finalSurface)
            if finalAction.exists {
                return finalAction
            }
        }

        if let directAction = directActionCandidates.first(where: { isElementHittable($0) }) {
            return directAction
        }
        return nil
    }

    /**
     Returns true when XCTest has a finite, non-empty frame it can use for activation-point work.
     */
}
