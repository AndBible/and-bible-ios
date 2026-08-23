import XCTest

/**
 Package-level source-contract guards for reader shell parity that cannot be observed directly.

 These tests inspect narrow BibleUI function boundaries where SwiftUI coordinator state is private.
 They keep Android/Vue parity for anchored quick selectors and active-window chrome without
 requiring the app-host XCTest bundle.
 */
final class ReaderSourceGuardTests: XCTestCase {
    /**
     Guards the reader coordinator against regressing to the iOS sheet for the quick-menu path.

     The coordinator state is intentionally private, so this source-level test checks the routing
     contract at the function boundary: Android's `menuForDocs` equivalent must route the resolved
     quick-selector rows into the popup, the toolbar button must publish anchor geometry for an
     in-reader popup, and module actions must be disabled until the focused pane controller exists,
     including accessibility exposure. Row selection must also dismiss the popup before checking
     whether the captured controller still exists. Bible/commentary toolbar gestures must dispatch
     tap or long-press exclusively so Android's quick-menu and full-chooser paths cannot both fire
     for one press. A failure means the user-visible selector likely drifted back toward the old
     full-sheet behavior, can accept taps before the Android-equivalent document state is available,
     can leave a stale popup onscreen after pane teardown, or can fire both selector paths from one
     toolbar gesture.
     */
    func testBibleToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try BibleUITestSourceLocator.extractFunction(
            named: "performBibleMenuAction",
            from: readerSource
        )
        let selectionSource = try BibleUITestSourceLocator.extractFunction(
            named: "selectBibleQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("case .showPopup(let rows):"))
        XCTAssertTrue(menuActionSource.contains("presentBibleQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performBibleChooserAction()"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("let rows = bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("let targetWindowId = bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("selectBibleQuickModule(module, targetWindowId: targetWindowId)"))
        XCTAssertTrue(readerSource.contains("moduleActionsEnabled: controller != nil"))
        XCTAssertTrue(readerSource.contains("ReaderBibleToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderBibleToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(toolbarSource.contains(".disabled(!moduleActionsEnabled)"))
        XCTAssertFalse(toolbarSource.contains(".simultaneousGesture(LongPressGesture"))
        XCTAssertTrue(toolbarSource.contains("LongPressGesture().exclusively(before: TapGesture())"))
        XCTAssertFalse(readerSource.contains("suppressBibleTapAfterLongPress"))
        XCTAssertFalse(readerSource.contains("suppressCommentaryTapAfterLongPress"))
        XCTAssertEqual(toolbarSource.components(separatedBy: "moduleToolbarAction(").count - 1, 2)
        XCTAssertTrue(toolbarSource.contains(".accessibilityHidden(!moduleActionsEnabled)"))
        XCTAssertTrue(selectionSource.contains("let controller = controller(for: targetWindowId)"))
        let resolveIndex = try XCTUnwrap(selectionSource.range(of: "let controller = controller(for: targetWindowId)")?.lowerBound)
        let dismissIndex = try XCTUnwrap(selectionSource.range(of: "dismissBibleQuickSelector()")?.lowerBound)
        XCTAssertLessThan(resolveIndex, dismissIndex)
    }

    /**
     Guards Android's split between unlocked normal shortcuts and the inclusive full chooser.

     - Setup: Extracts the private toolbar menu, next-document, suggested-Bible, Search, and chooser
       inventory boundaries from BibleUI source.
     - Expected result: Every automatic/quick/Search Bible path consumes the controller's
       one-snapshot readable projection, while the full picker still consumes
       `installedModules(for:)`.
     - Failure meaning: Locked Bibles can re-enter a no-prompt shortcut, or disappear from the only
       chooser that owns the existing passphrase flow.
     - Side effects: Reads package source only.
     */
    func testBibleNormalSelectorsExcludeLockedRowsWithoutNarrowingFullChooser() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let pickerSource = try bibleUISource(named: "BibleReaderModulePicker.swift")
        let menuActionSource = try BibleUITestSourceLocator.extractFunction(
            named: "performBibleMenuAction",
            from: readerSource
        )
        let nextActionSource = try BibleUITestSourceLocator.extractFunction(
            named: "performBibleNextDocumentAction",
            from: readerSource
        )
        let suggestedSource = try BibleUITestSourceLocator.extractFunction(
            named: "suggestedBibleDocumentName",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("for: controller.readableBibleModules"))
        XCTAssertTrue(nextActionSource.contains("modules: controller.readableBibleModules"))
        XCTAssertTrue(suggestedSource.contains("let readableModules = controller.readableBibleModules"))
        XCTAssertTrue(readerSource.contains("installedBibleModules: controller?.readableBibleModules ?? []"))
        XCTAssertTrue(pickerSource.contains("controller.installedModules(for: $0)"))
        XCTAssertFalse(pickerSource.contains("controller.readableBibleModules"))
    }

    /**
     Guards the commentary toolbar quick-menu route against preserving the old iOS sheet.

     Android default commentary taps show an anchored `PopupMenu` with commentaries, general books,
     and dictionaries while the reader remains visible. Long press remains the full
     `ChooseDocument` activity path except for Android's `swap-menu` setting. The SwiftUI
     coordinator state is private, so this source-level contract checks the same boundary as the
     Bible quick-menu test: commentary tap must resolve rows, show the anchored popup, anchor from
     the commentary toolbar button, and route selections through category-specific current-document
     switch methods.
     */
    func testCommentaryToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try BibleUITestSourceLocator.extractFunction(
            named: "performCommentaryMenuAction",
            from: readerSource
        )
        let selectionSource = try BibleUITestSourceLocator.extractFunction(
            named: "selectCommentaryQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("BibleReaderQuickModuleSelectorPresentation.action("))
        XCTAssertTrue(menuActionSource.contains("commentaryQuickSelectorModules("))
        XCTAssertTrue(menuActionSource.contains("presentCommentaryQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performCommentaryChooserAction()"))
        XCTAssertTrue(readerSource.contains("performCommentaryMenuAction(controller, includeAuxiliaryDocuments: false)"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedGeneralBookModules"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedDictionaryModules"))
        XCTAssertTrue(readerSource.contains("controller.installedCommentaryModules.filter(\\.isUnlocked)"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorOverlay(anchor: anchor)"))
        XCTAssertTrue(readerSource.contains("ReaderCommentaryToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderCommentaryToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(selectionSource.contains("case .commentary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchCommentaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .dictionary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchDictionaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .generalBook:"))
        XCTAssertTrue(selectionSource.contains("controller.switchGeneralBookDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("dismissCommentaryQuickSelector()"))
    }

    /**
     Verifies active-pane rendering stays owned by the Android/Vue active-window indicator.

     Android emits `set_active` into each web reader and draws corner markers inside `BibleView.vue`.
     A native SwiftUI border around the pane creates an extra full blue rectangle that Android does
     not draw, especially visible in multi-window dictionary layouts. The source assertion protects
     that boundary because the visual marker is intentionally split between native focus routing and
     web-rendered reader chrome.
     */
    func testReaderPaneDoesNotAddNativeAccentBorderForActiveWindow() throws {
        let paneSource = try bibleUISource(named: "BibleWindowPane.swift")
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let controllerSource = try bibleUISource(named: "BibleReaderController.swift")
        let coordinatorSource = try bibleUISource(named: "BibleReaderConfigurationCoordinator.swift")
        let paneViewSource = try BibleUITestSourceLocator.extractFunction(named: "paneView", from: readerSource)

        XCTAssertFalse(paneSource.contains(".border(isFocused"))
        XCTAssertFalse(paneSource.contains("Color.accentColor"))
        XCTAssertFalse(paneViewSource.contains("isFocused:"))
        XCTAssertTrue(controllerSource.contains("activeWindowState()"))
        XCTAssertTrue(controllerSource.contains("set_active"))
        XCTAssertTrue(coordinatorSource.contains("hasActiveIndicator"))
    }

    /**
     Verifies Android-style pane menu buttons retain stable iOS accessibility output.

     The pane button intentionally renders Android's literal hamburger glyph instead of an iOS
     system button. This guard keeps VoiceOver from deriving an unstable label from that glyph or
     from the links-window marker icon. A failure means the Android visual parity control is no
     longer exposed as a predictable iOS accessibility button.
     */
    func testAndroidPaneWindowButtonHasExplicitAccessibilityLabel() throws {
        let paneSource = try bibleUISource(named: "BibleWindowPane.swift")

        XCTAssertTrue(paneSource.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(paneSource.contains(".accessibilityLabel("))
        XCTAssertTrue(paneSource.contains(".accessibilityHint("))
        XCTAssertTrue(paneSource.contains("window_menu_accessibility_label"))
        XCTAssertTrue(paneSource.contains("window_menu_accessibility_hint"))
    }

    /**
     Verifies Android-style footer restore controls do not expose icon-derived accessibility text.

     The maximized-window footer control is intentionally an Android restore affordance rendered
     with an iOS symbol. Without an explicit label, VoiceOver can announce the symbol name instead
     of the window action, which creates an accessibility-only drift from the window-control
     contract while leaving the visual parity intact.
     */
    func testAndroidFooterUnmaximizeButtonHasExplicitAccessibilityLabel() throws {
        let tabBarSource = try bibleUISource(named: "WindowTabBar.swift")
        let unmaximizeSource = try BibleUITestSourceLocator.extractFunction(
            named: "unmaximizeButton",
            from: tabBarSource
        )

        XCTAssertTrue(unmaximizeSource.contains(".accessibilityLabel("))
        XCTAssertTrue(unmaximizeSource.contains(".accessibilityHint("))
        XCTAssertTrue(unmaximizeSource.contains("window_unmaximize_accessibility_label"))
        XCTAssertTrue(unmaximizeSource.contains("window_unmaximize_accessibility_hint"))
    }

    /**
     Guards synchronized panes against exchanging module-local ordinals across versifications.

     Android copies one `Verse` identity and resolves it in every target document. The SwiftUI
     callback is private coordinator state, so this source boundary asserts that the source ordinal
     is first converted to a stable reference, every target uses `scrollToSynchronizedVerse`, and
     neither of the former raw-ordinal fallback routes survives. A failure can move a divergent-canon
     target to an unrelated verse while appearing to synchronize successfully.
     */
    func testSynchronizedWindowsRequireVerifiedVerseConversionBeforeTargetNavigation() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let synchronizationSource = try BibleUITestSourceLocator.extractFunction(
            named: "installSynchronizedScrollingCallback",
            from: readerSource
        )

        XCTAssertTrue(synchronizationSource.contains("synchronizedVerseReference(ordinal: ordinal)"))
        XCTAssertTrue(synchronizationSource.contains("ctrl.scrollToSynchronizedVerse("))
        XCTAssertFalse(synchronizationSource.contains("ctrl.scrollToOrdinal(ordinal)"))
        XCTAssertFalse(synchronizationSource.contains("navigateToSynchronizedPosition"))
    }

    /**
     Loads a Bible reader UI source file for source-level contract tests.

     Source assertions are used only where SwiftUI coordinator state is intentionally private and a
     pure behavior test cannot observe the routing boundary. The shared locator derives the path
     from the current test bundle so it works in local and CI checkouts without hard-coded absolute
     paths.
     */
    private func bibleUISource(named fileName: String) throws -> String {
        try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/\(fileName)"
        )
    }
}
