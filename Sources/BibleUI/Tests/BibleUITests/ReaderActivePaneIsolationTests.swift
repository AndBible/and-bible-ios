// ReaderActivePaneIsolationTests.swift -- package coverage for multi-pane action targeting

import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Package-level coverage for reader actions that must stay scoped to the captured pane.

 The removed app-host UI smokes covered third-window bookmark navigation, document switching, and
 Strong's toolbar toggles by launching the whole app. These tests cover the same Android parity
 contract at the owning seams: pane presentation routing, window-scoped text settings, and real
 reader-controller page-manager mutations.
 */
final class ReaderActivePaneIsolationTests: BibleUISwordFixtureTestCase {
    /**
     Protects captured pane routing from drifting to a newly focused pane.

     Android opens pane menus against the pane that produced the menu action. When iOS has a
     captured target, controller/window resolution must use that target and must not fall back to the
     current active pane if the captured target is temporarily unavailable.
     */
    func testPanePresentationRoutingUsesCapturedWindowBeforeFocusedWindow() {
        let focusedWindow = Window(orderNumber: 0)
        let targetWindow = Window(orderNumber: 2)
        let focusedController = PaneControllerProbe(name: "focused")
        let targetController = PaneControllerProbe(name: "target")

        let capturedWindowId = BibleReaderPanePresentationTarget.capturedWindowId(
            requested: targetWindow.id,
            activeWindow: focusedWindow
        )

        XCTAssertEqual(capturedWindowId, targetWindow.id)
        XCTAssertTrue(
            BibleReaderPanePresentationTarget.controller(
                targetWindowId: capturedWindowId,
                controllers: [
                    focusedWindow.id: focusedController,
                    targetWindow.id: targetController,
                ],
                activeWindow: focusedWindow,
                as: PaneControllerProbe.self
            ) === targetController
        )
        XCTAssertEqual(
            BibleReaderPanePresentationTarget.window(
                targetWindowId: capturedWindowId,
                allWindows: [focusedWindow, targetWindow],
                activeWindow: focusedWindow
            )?.id,
            targetWindow.id
        )

        let missingCapturedWindowId = UUID()
        XCTAssertNil(
            BibleReaderPanePresentationTarget.controller(
                targetWindowId: missingCapturedWindowId,
                controllers: [focusedWindow.id: focusedController],
                activeWindow: focusedWindow,
                as: PaneControllerProbe.self
            )
        )
        XCTAssertNil(
            BibleReaderPanePresentationTarget.window(
                targetWindowId: missingCapturedWindowId,
                allWindows: [focusedWindow],
                activeWindow: focusedWindow
            )
        )

        XCTAssertTrue(
            BibleReaderPanePresentationTarget.controller(
                targetWindowId: nil,
                controllers: [focusedWindow.id: focusedController],
                activeWindow: focusedWindow,
                as: PaneControllerProbe.self
            ) === focusedController
        )
        XCTAssertEqual(
            BibleReaderPanePresentationTarget.window(
                targetWindowId: nil,
                allWindows: [focusedWindow, targetWindow],
                activeWindow: focusedWindow
            )?.id,
            focusedWindow.id
        )
    }

    /**
     Protects Android's window-scoped Strong's toggle ownership.

     The toolbar quick toggle writes a window-level text-display override for the active/captured
     pane only. The sequence mirrors the removed UI smoke: toggle the third pane on, toggle the first
     pane on, then cycle the third pane back to inherited hidden links while the first pane remains
     explicit.
     */
    func testWindowScopedStrongsModeMutationTouchesOnlyTargetPane() {
        let sourceWindow = windowWithPageManager(orderNumber: 0)
        let targetWindow = windowWithPageManager(orderNumber: 2)
        let parentSettings = TextDisplaySettings.appDefaults

        persistStrongsMode(1, to: targetWindow, parentSettings: parentSettings)

        XCTAssertEqual(resolvedStrongsMode(for: targetWindow), 1)
        XCTAssertEqual(resolvedStrongsMode(for: sourceWindow), 0)
        XCTAssertNil(sourceWindow.pageManager?.textDisplaySettings?.strongsMode)

        persistStrongsMode(1, to: sourceWindow, parentSettings: parentSettings)

        XCTAssertEqual(resolvedStrongsMode(for: sourceWindow), 1)
        XCTAssertEqual(resolvedStrongsMode(for: targetWindow), 1)

        persistStrongsMode(2, to: targetWindow, parentSettings: parentSettings)
        persistStrongsMode(0, to: targetWindow, parentSettings: parentSettings)

        XCTAssertEqual(resolvedStrongsMode(for: targetWindow), 0)
        XCTAssertNil(targetWindow.pageManager?.textDisplaySettings?.strongsMode)
        XCTAssertEqual(resolvedStrongsMode(for: sourceWindow), 1)
        XCTAssertEqual(sourceWindow.pageManager?.textDisplaySettings?.strongsMode, 1)
    }

    /**
     Protects bookmark-list navigation from mutating the focused pane after a pane menu capture.

     Android applies bookmark row navigation to the pane whose menu opened the bookmark list. This
     test resolves the captured third-pane controller while the first pane is still active, performs
     real controller navigation, and asserts only the captured pane's Bible state moves to Exodus 2.
     */
    @MainActor
    func testBookmarkNavigationUsesCapturedPaneControllerWithoutMutatingFocusedPane() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceWindow = windowWithPageManager(orderNumber: 0)
        let targetWindow = windowWithPageManager(orderNumber: 2)
        let sourceController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        sourceController.activeWindow = sourceWindow
        targetController.activeWindow = targetWindow
        sourceController.navigateTo(book: "Genesis", chapter: 1)
        targetController.navigateTo(book: "Genesis", chapter: 1)

        let routedController = try XCTUnwrap(
            BibleReaderPanePresentationTarget.controller(
                targetWindowId: targetWindow.id,
                controllers: [
                    sourceWindow.id: sourceController,
                    targetWindow.id: targetController,
                ],
                activeWindow: sourceWindow,
                as: BibleReaderController.self
            )
        )

        routedController.navigateTo(book: "Exodus", chapter: 2)

        XCTAssertTrue(routedController === targetController)
        XCTAssertEqual(targetController.currentBook, "Exodus")
        XCTAssertEqual(targetController.currentChapter, 2)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 2)
        XCTAssertEqual(sourceController.currentBook, "Genesis")
        XCTAssertEqual(sourceController.currentChapter, 1)
        XCTAssertEqual(sourceWindow.pageManager?.bibleChapterNo, 1)
    }

    /**
     Protects document switching from changing sibling pane content.

     Android document selectors update the current pane's page manager and category atomically. This
     test routes selections to the captured third-pane controller, switches it to commentary and
     back to a Bible module, and verifies the first pane remains a Genesis/KJV Bible pane.
     */
    @MainActor
    func testDocumentSwitchMutatesOnlyCapturedPaneDocumentState() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedBibleAliasModule(named: "WEB", description: "World English Bible", in: modulePath)
        try seedEmptyRawCommentaryModule(named: "UITestComm", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceWindow = windowWithPageManager(orderNumber: 0)
        let targetWindow = windowWithPageManager(orderNumber: 2)
        let sourceController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        sourceController.activeWindow = sourceWindow
        targetController.activeWindow = targetWindow
        sourceController.navigateTo(book: "Genesis", chapter: 1)
        targetController.navigateTo(book: "Genesis", chapter: 1)
        let sourceModuleBeforeSwitch = sourceController.activeModuleName
        let sourceCategoryBeforeSwitch = sourceController.currentCategory

        let routedController = try XCTUnwrap(
            BibleReaderPanePresentationTarget.controller(
                targetWindowId: targetWindow.id,
                controllers: [
                    sourceWindow.id: sourceController,
                    targetWindow.id: targetController,
                ],
                activeWindow: sourceWindow,
                as: BibleReaderController.self
            )
        )

        routedController.switchCommentaryDocument(to: "UITestComm")

        XCTAssertTrue(routedController === targetController)
        XCTAssertEqual(targetController.currentCategory, .commentary)
        XCTAssertEqual(targetController.activeCommentaryModuleName, "UITestComm")
        XCTAssertEqual(targetWindow.pageManager?.commentaryDocument, "UITestComm")
        XCTAssertEqual(targetWindow.pageManager?.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(sourceController.currentCategory, sourceCategoryBeforeSwitch)
        XCTAssertEqual(sourceController.activeModuleName, sourceModuleBeforeSwitch)
        XCTAssertEqual(sourceWindow.pageManager?.currentCategoryName, DocumentCategory.bible.pageManagerKey)

        routedController.switchBibleDocument(to: "WEB")

        XCTAssertEqual(targetController.currentCategory, .bible)
        XCTAssertEqual(targetController.activeModuleName, "WEB")
        XCTAssertEqual(targetWindow.pageManager?.bibleDocument, "WEB")
        XCTAssertEqual(targetWindow.pageManager?.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(sourceController.currentCategory, sourceCategoryBeforeSwitch)
        XCTAssertEqual(sourceController.activeModuleName, sourceModuleBeforeSwitch)
        XCTAssertEqual(sourceWindow.pageManager?.bibleDocument, nil)
        XCTAssertEqual(sourceWindow.pageManager?.currentCategoryName, DocumentCategory.bible.pageManagerKey)
    }

    /**
     Creates an isolated window and page manager pair for pane-scoped tests.

     - Parameter orderNumber: Zero-based pane order to assign.
     - Returns: A window whose `pageManager` identifier mirrors the window identifier.
     - Side effects: Allocates SwiftData model instances without inserting them into a context.
     - Failure modes: None.
     */
    private func windowWithPageManager(orderNumber: Int) -> Window {
        let window = Window(orderNumber: orderNumber)
        window.pageManager = PageManager(id: window.id)
        return window
    }

    /**
     Persists one Strong's mode as a window-scoped text-display override.

     - Parameters:
       - mode: Android Strong's mode integer to persist.
       - window: Target pane.
       - parentSettings: Effective workspace/global parent settings.
     - Side effects: Mutates `window.pageManager.textDisplaySettings`.
     - Failure modes: Records an XCTest failure if the window does not have a page manager.
     */
    private func persistStrongsMode(
        _ mode: Int,
        to window: Window,
        parentSettings: TextDisplaySettings
    ) {
        var nextSettings = TextDisplaySettings.fullyResolved(
            window: window.pageManager?.textDisplaySettings,
            workspace: nil,
            global: nil
        )
        let previousSettings = nextSettings
        nextSettings.strongsMode = mode

        XCTAssertTrue(
            BibleReaderWindowDisplaySettingsMutation.persist(
                editorSettings: nextSettings,
                for: window,
                parentSettings: parentSettings,
                previousResolvedSettings: previousSettings
            )
        )
    }

    /**
     Resolves one pane's effective Strong's mode through normal text-display inheritance.

     - Parameter window: Pane whose display settings should be resolved.
     - Returns: Concrete Strong's mode, defaulting to hidden links when missing.
     - Side effects: None.
     - Failure modes: None.
     */
    private func resolvedStrongsMode(for window: Window) -> Int {
        TextDisplaySettings.fullyResolved(
            window: window.pageManager?.textDisplaySettings,
            workspace: nil,
            global: nil
        ).strongsMode ?? StrongsMode.hiddenLinks.rawValue
    }
}

private final class PaneControllerProbe {
    let name: String

    init(name: String) {
        self.name = name
    }
}
