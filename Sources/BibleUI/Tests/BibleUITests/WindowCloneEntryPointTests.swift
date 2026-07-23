// WindowCloneEntryPointTests.swift -- Pane duplication source-routing contracts

import XCTest

/**
 Guards the private SwiftUI actions that initiate pane duplication.

 Core behavior tests cover the cloned graph. These source-boundary checks ensure the footer and
 pane menu both pass the selected source window into that behavior instead of creating a fresh
 default-category pane before the model layer can preserve its reader state.
 */
final class WindowCloneEntryPointTests: XCTestCase {
    /**
     Verifies both user-facing duplicate actions forward their exact source pane.

     The footer must use the active window and a pane menu must use its represented window. A
     failure means non-Bible content can be discarded before `WindowManager` receives a clone
     request, even when its model-level copy behavior remains correct.
     */
    func testPaneDuplicationEntrypointsForwardTheSelectedSourceWindow() throws {
        let tabBarSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/WindowTabBar.swift"
        )
        let paneSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift"
        )
        let actionHandlerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPaneMenuActionHandler.swift"
        )
        let footerAction = try BibleUITestSourceLocator.extractFunction(
            named: "addWindowButton",
            from: tabBarSource
        )
        let paneMenuAction = try BibleUITestSourceLocator.extractFunction(
            named: "performWindowMenuAction",
            from: paneSource
        )
        let sharedMenuAction = try BibleUITestSourceLocator.extractFunction(
            named: "perform",
            from: actionHandlerSource
        )

        XCTAssertTrue(footerAction.contains("windowManager.addWindow(from: windowManager.activeWindow)"))
        XCTAssertFalse(footerAction.contains("category: \"bible\""))
        XCTAssertTrue(paneMenuAction.contains("BibleWindowPaneMenuActionHandler("))
        XCTAssertTrue(paneMenuAction.contains("window: window"))
        XCTAssertTrue(paneMenuAction.contains(").perform(action)"))
        XCTAssertFalse(paneMenuAction.contains("category: \"bible\""))
        XCTAssertTrue(sharedMenuAction.contains("case .newWindow:"))
        XCTAssertTrue(sharedMenuAction.contains("windowManager.addWindow(from: window)"))
        XCTAssertFalse(sharedMenuAction.contains("category: \"bible\""))
    }
}
