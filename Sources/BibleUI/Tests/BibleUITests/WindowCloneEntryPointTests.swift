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
        let footerAction = try BibleUITestSourceLocator.extractFunction(
            named: "addWindowButton",
            from: tabBarSource
        )
        let paneMenuAction = try BibleUITestSourceLocator.extractFunction(
            named: "performWindowMenuAction",
            from: paneSource
        )

        XCTAssertTrue(footerAction.contains("windowManager.addWindow(from: windowManager.activeWindow)"))
        XCTAssertFalse(footerAction.contains("category: \"bible\""))
        XCTAssertTrue(paneMenuAction.contains("case .newWindow:"))
        XCTAssertTrue(paneMenuAction.contains("windowManager.addWindow(from: window)"))
        XCTAssertFalse(paneMenuAction.contains("category: \"bible\""))
    }
}
