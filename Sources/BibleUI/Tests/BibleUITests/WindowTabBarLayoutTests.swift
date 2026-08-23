import Foundation
import XCTest
import BibleCore
@testable import BibleUI

/**
 Verifies the bottom reader window-strip layout contracts that mirror Android's compact
 multi-window footer behavior without requiring the app-host XCTest bundle.
 */
final class WindowTabBarLayoutTests: XCTestCase {
    /**
     Protects Android-style compact bottom window buttons on phone-width readers.

     Android uses fixed-size window buttons instead of variable-width text pills, and the
     multi-window restore strip reserves a hide/restore arrow rather than the add-window button. The
     tested iPhone width is the practical regression case from local Simulator testing: four windows
     plus the Android arrow control must fit without relying on horizontal scrolling, while larger
     window counts may reduce to the minimum compact size.
     */
    func testFourReaderWindowsAndRestoreToggleFitInPhoneFooter() {
        let tabWidth = WindowTabBarLayout.tabWidth()
        let occupiedWidth = WindowTabBarLayout.multiWindowOccupiedWidth(tabWidth: tabWidth, windowCount: 4)

        XCTAssertLessThanOrEqual(occupiedWidth, 430)
        XCTAssertGreaterThanOrEqual(tabWidth, WindowTabBarLayout.minimumTabWidth)
        XCTAssertLessThanOrEqual(tabWidth, WindowTabBarLayout.maximumTabWidth)
    }

    /**
     Protects Android's footer action split between single-window and multi-window modes.

     Android shows `AddNewWindowButtonWidget` only for a true single-window workspace. Once multiple
     windows exist, the footer switches that affordance to the hide/restore arrow at the leading
     edge of the restore-button strip. A failure here means iOS has drifted back toward showing a
     new-window button in a multi-window footer where Android exposes the strip toggle instead.
     */
    func testMultiWindowFooterReservesRestoreToggleInsteadOfAddButton() {
        XCTAssertEqual(WindowTabBarLayout.singleWindowControlWidth, WindowTabBarLayout.fixedButtonSize)
        XCTAssertEqual(
            WindowTabBarLayout.multiWindowControlWidth,
            WindowTabBarLayout.restoreToggleTouchExtensionWidth + WindowTabBarLayout.restoreToggleButtonWidth
        )
    }

    /**
     Protects Android's hidden restore-strip bottom offset contract.

     Android removes `windowButtonHeight` from the WebView bottom offset when the multi-window
     restore strip is hidden, while leaving only the hide/show affordance translated onto the
     screen edge. iOS must not reserve a full-height bottom bar in that state because it shortens
     the reader content differently than Android.
     */
    func testHiddenMultiWindowFooterDoesNotReserveReaderHeight() {
        XCTAssertEqual(
            WindowTabBarLayout.reservedHeight(
                restoreButtonsVisible: false,
                isSingleWindowFooterMode: false
            ),
            WindowTabBarLayout.collapsedBarHeight
        )
    }

    /**
     Protects Android's expanded and single-window footer height contract.

     Android reserves `windowButtonHeight` while restore buttons are visible and forces the restore
     strip visible in single-window mode so the add-window button remains a normal bottom control.
     */
    func testVisibleOrSingleWindowFooterReservesReaderHeight() {
        XCTAssertEqual(
            WindowTabBarLayout.reservedHeight(
                restoreButtonsVisible: true,
                isSingleWindowFooterMode: false
            ),
            WindowTabBarLayout.barHeight
        )
        XCTAssertEqual(
            WindowTabBarLayout.reservedHeight(
                restoreButtonsVisible: false,
                isSingleWindowFooterMode: true
            ),
            WindowTabBarLayout.barHeight
        )
    }

    /**
     Protects the hidden restore affordance hit width.

     Android leaves the 20dp extension plus 30dp arrow reachable when the strip is hidden; iOS adds
     only its existing horizontal inset around that control and must not keep a full-width footer
     surface visible.
     */
    func testCollapsedFooterOnlyKeepsRestoreAffordanceWidth() {
        XCTAssertEqual(
            WindowTabBarLayout.collapsedControlWidth,
            WindowTabBarLayout.multiWindowControlWidth + WindowTabBarLayout.horizontalPadding
        )
    }

    /**
     Protects the lower bound for dense tab sets.

     The footer should not shrink window buttons below their legible Android-style compact shape
     just to force unusually large tab counts onto one screen. A failure means the layout has moved
     back toward squeezing text until the icon/title/reference identity is no longer readable.
     */
    func testManyReaderWindowsClampToMinimumCompactWidth() {
        let tabWidth = WindowTabBarLayout.tabWidth()

        XCTAssertEqual(tabWidth, WindowTabBarLayout.minimumTabWidth)
    }

    /**
     Protects Android restore-button visibility toggling on the shared iOS and macOS footer.

     Android's `SplitBibleArea.createRestoreButton` sends every button tap to
     `WindowControl.restoreWindow`: a visible pane minimizes, while a minimized pane restores.
     The recording target proves SwiftUI delegates one visibility-toggle command instead of deciding
     the lifecycle branch from rendered state. Manager tests cover the resulting minimize, restore,
     and transient-links closure branches. A failure means the footer has resumed treating a visible
     window button like a conventional focus-only tab.
     */
    func testWindowTabSelectionDelegatesAndroidRestoreButtonBehaviorToManager() {
        let window = BibleCore.Window()
        let target = RecordingWindowTabActionTarget()
        let dispatcher = WindowTabActionDispatcher(target: target)

        dispatcher.perform(.select, for: window)

        XCTAssertEqual(target.calls, [
            .toggleVisibility(window.id),
        ])
    }

    /**
     Executes every state-changing tab command through the dispatcher used by `WindowTabBar`.

     The recording target stands in for `WindowManager` and proves selection, focus, movement,
     synchronization, pinning, grouping, layout, and close actions delegate exactly once without
     directly mutating the window fixture. Selection delegates Android's restore-strip behavior to
     the manager rather than branching from the view's snapshot. A failure means the UI command seam
     no longer preserves the manager-owned lifecycle contract.
    */
    func testWindowTabDispatcherRoutesEveryMutationToManagerBoundary() {
        let window = BibleCore.Window(isSynchronized: true, isPinMode: false, syncGroup: 0)
        let target = RecordingWindowTabActionTarget()
        let dispatcher = WindowTabActionDispatcher(target: target)

        dispatcher.perform(.select, for: window)
        dispatcher.perform(.activate, for: window)
        dispatcher.perform(.restore, for: window)
        dispatcher.perform(.move(toPosition: 3), for: window)
        dispatcher.perform(.minimize, for: window)
        dispatcher.perform(.maximize, for: window)
        dispatcher.perform(.unmaximize, for: window)
        dispatcher.perform(.setSynchronized(false), for: window)
        dispatcher.perform(.setPinMode(true), for: window)
        dispatcher.perform(.changeSyncGroup(4), for: window)
        dispatcher.perform(.close, for: window)

        let expectedCalls: [RecordingWindowTabActionTarget.Call] = [
            .toggleVisibility(window.id),
            .activate(window.id),
            .restore(window.id),
            .move(window.id, position: 3),
            .minimize(window.id),
            .maximize(window.id),
            .unmaximize,
            .setSynchronized(window.id, value: false),
            .setPinMode(window.id, value: true),
            .changeSyncGroup(window.id, group: 4),
            .remove(window.id),
        ]
        XCTAssertEqual(target.calls, expectedCalls)
        XCTAssertTrue(window.isSynchronized)
        XCTAssertFalse(window.isPinMode)
        XCTAssertEqual(window.syncGroup, 0)
    }

    /**
     Executes the separator's production drag session against recorded effective weights.

     The first event snapshots manager-projected weights, later events remain relative to that same
     snapshot, transient writes are non-persistent, and gesture completion persists the final pair
     exactly once. A failure means separator wiring can compound drag deltas, bypass effective
     auto-pin weights, or leave the final Android-style split ratio unsaved.
     */
    func testWindowSeparatorDragUsesEffectiveWeightsAndPersistsOnlyFinalPair() {
        let firstWindow = BibleCore.Window()
        let secondWindow = BibleCore.Window()
        let target = RecordingWindowSeparatorResizeTarget(effectiveWeights: [
            firstWindow.id: 1.5,
            secondWindow.id: 0.75,
        ])
        var session = WindowSeparatorDragSession()

        session.update(
            translation: 50,
            parentSize: 400,
            totalPaneCount: 2,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            target: target
        )
        session.update(
            translation: 200,
            parentSize: 400,
            totalPaneCount: 2,
            firstWindow: firstWindow,
            secondWindow: secondWindow,
            target: target
        )

        XCTAssertTrue(session.isDragging)
        session.finish(firstWindow: firstWindow, secondWindow: secondWindow, target: target)
        session.finish(firstWindow: firstWindow, secondWindow: secondWindow, target: target)
        XCTAssertFalse(session.isDragging)

        XCTAssertEqual(target.effectiveWeightRequests, [firstWindow.id, secondWindow.id])
        XCTAssertEqual(target.resizeCalls.map(\.persist), [false, false, true])
        XCTAssertEqual(target.resizeCalls[0].firstWeight, 1.75, accuracy: 0.0001)
        XCTAssertEqual(target.resizeCalls[0].secondWeight, 0.5, accuracy: 0.0001)
        XCTAssertEqual(target.resizeCalls[1].firstWeight, 2.5, accuracy: 0.0001)
        XCTAssertEqual(target.resizeCalls[1].secondWeight, 0.1, accuracy: 0.0001)
        XCTAssertEqual(target.resizeCalls[2].firstWeight, 2.5, accuracy: 0.0001)
        XCTAssertEqual(target.resizeCalls[2].secondWeight, 0.1, accuracy: 0.0001)
        XCTAssertTrue(target.resizeCalls.allSatisfy {
            $0.firstWindowID == firstWindow.id && $0.secondWindowID == secondWindow.id
        })
        XCTAssertEqual(firstWindow.layoutWeight, 1)
        XCTAssertEqual(secondWindow.layoutWeight, 1)
    }

    /**
     Verifies weighted panes and fixed separators exactly fit their parent geometry.

     A failure means each separator is added after panes already consume the full extent, producing
     clipping or off-screen content in multi-pane horizontal and vertical layouts.
     */
    func testBibleReaderSplitLayoutReservesSeparatorExtent() {
        let parentExtent: CGFloat = 430
        let paneExtent = BibleReaderSplitLayout.availablePaneExtent(
            totalExtent: parentExtent,
            paneCount: 3
        )
        let separatorExtent = CGFloat(2) * BibleReaderSplitLayout.separatorThickness

        XCTAssertEqual(paneExtent, 422, accuracy: 0.001)
        XCTAssertEqual(paneExtent + separatorExtent, parentExtent, accuracy: 0.001)
        XCTAssertEqual(
            BibleReaderSplitLayout.availablePaneExtent(totalExtent: 3, paneCount: 2),
            0,
            accuracy: 0.001
        )
    }

    /**
     Protects Android's configuration-orientation split contract while the software keyboard is open.

     Android chooses `SplitBibleArea` orientation from `Configuration.orientation`; IME insets resize
     content but cannot turn portrait into landscape. The iOS pure resolver receives stable owning-
     window bounds, while the keyboard-adjusted local extent remains relevant only to pane sizing.

     - Setup: Uses the reported iPhone portrait window (402x874) and its keyboard-reduced reader height
       (297 points), plus a true landscape window and reverse-split preference.
     - Expected Result: Portrait remains vertical across the reduced extent, real landscape resolves
       horizontal, reverse mode deterministically inverts both, and local extent sizing still works.
     - Failure Meaning: Focusing a note can reconstruct the pane hierarchy and detach its WebView.
     - Side Effects: None; this test executes only pure geometry functions.
     */
    func testBibleReaderSplitAxisUsesStableWindowGeometryAcrossKeyboardResize() {
        let portraitWindow = CGSize(width: 402, height: 874)
        let landscapeWindow = CGSize(width: 874, height: 402)
        let keyboardReducedPaneExtent = BibleReaderSplitLayout.availablePaneExtent(
            totalExtent: 297,
            paneCount: 2
        )

        XCTAssertFalse(
            BibleReaderSplitLayout.isHorizontal(
                stableWindowSize: portraitWindow,
                reverseSplitMode: false
            )
        )
        XCTAssertTrue(
            BibleReaderSplitLayout.isHorizontal(
                stableWindowSize: portraitWindow,
                reverseSplitMode: true
            )
        )
        XCTAssertTrue(
            BibleReaderSplitLayout.isHorizontal(
                stableWindowSize: landscapeWindow,
                reverseSplitMode: false
            )
        )
        XCTAssertFalse(
            BibleReaderSplitLayout.isHorizontal(
                stableWindowSize: landscapeWindow,
                reverseSplitMode: true
            )
        )
        XCTAssertEqual(keyboardReducedPaneExtent, 293, accuracy: 0.001)
    }

    /**
     Guards pane-menu projections against bypassing Android's effective pin semantics.

     A failure means auto-pin can render or group pane-menu entries using stale raw pin values even
     though manager layout behavior uses the effective state.
     */
    func testBibleWindowPaneMenuUsesEffectivePinState() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift"
        )
        let snapshotFactorySource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPaneMenuSnapshotFactory.swift"
        )

        XCTAssertTrue(source.contains("BibleWindowPaneMenuSnapshotFactory.snapshot("))
        XCTAssertTrue(snapshotFactorySource.contains("isPinned: windowManager.isEffectivelyPinned(window)"))
        XCTAssertTrue(snapshotFactorySource.contains("isPinned: windowManager.isEffectivelyPinned(candidate)"))
        XCTAssertTrue(source.contains("windowManager.activateWindow(window)"))
        XCTAssertTrue(source.contains("wm.activateWindow(window)"))
        XCTAssertFalse(snapshotFactorySource.contains("isPinned: window.isPinMode"))
        XCTAssertFalse(snapshotFactorySource.contains("isPinned: candidate.isPinMode"))
        XCTAssertFalse(source.contains("windowManager.activeWindow = window"))
        XCTAssertFalse(source.contains("wm.activeWindow = window"))
    }

    /**
     Guards reader-level pinning and pane activation through `WindowManager` lifecycle APIs.

     A failure means the overflow or pane Strong's path can bypass Android-style visibility
     normalization, persistence, or restored-window activation by mutating models directly.
     */
    func testBibleReaderViewWindowMutationsRouteThroughWindowManager() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let overflowAction = try BibleUITestSourceLocator.extractFunction(
            named: "handleReaderOverflowMenuAction",
            from: source
        )
        let strongsPresentation = try BibleUITestSourceLocator.extractFunction(
            named: "presentWindowStrongsMode",
            from: source
        )

        XCTAssertTrue(overflowAction.contains("windowManager.setAutoPinEnabled(nextValue)"))
        XCTAssertFalse(overflowAction.contains("updateWorkspaceSettings { $0.autoPin ="))
        XCTAssertTrue(strongsPresentation.contains("windowManager.activateWindow(targetWindow)"))
        XCTAssertFalse(strongsPresentation.contains("windowManager.activeWindow = targetWindow"))
    }

}

/**
 Records typed tab actions without applying `WindowManager` behavior.

 The recorder intentionally stores only method identity and arguments. It does not mutate models,
 normalize layout, or persist, so dispatcher tests fail if production routing is bypassed.
 */
private final class RecordingWindowTabActionTarget: WindowTabActionTarget {
    /// One manager-boundary call observed by the recorder.
    enum Call: Equatable {
        /// Window activation request.
        case activate(UUID)
        /// Android restore-strip visibility-toggle request.
        case toggleVisibility(UUID)
        /// Window restoration request.
        case restore(UUID)
        /// Window movement request and zero-based destination.
        case move(UUID, position: Int)
        /// Window minimization request.
        case minimize(UUID)
        /// Window maximization request.
        case maximize(UUID)
        /// Workspace unmaximize request.
        case unmaximize
        /// Synchronized-scrolling state request.
        case setSynchronized(UUID, value: Bool)
        /// Pin-mode state request.
        case setPinMode(UUID, value: Bool)
        /// Synchronization-group selection request.
        case changeSyncGroup(UUID, group: Int)
        /// Window removal request.
        case remove(UUID)
    }

    /// Ordered manager-boundary calls received from the dispatcher.
    private(set) var calls: [Call] = []

    /// Records activation without mutating the window.
    func activateWindow(_ window: BibleCore.Window) { calls.append(.activate(window.id)) }

    /// Records Android restore-strip selection without mutating the window.
    func toggleWindowVisibility(_ window: BibleCore.Window) {
        calls.append(.toggleVisibility(window.id))
    }

    /// Records restoration without mutating the window.
    func restoreWindow(_ window: BibleCore.Window) { calls.append(.restore(window.id)) }

    /// Records movement without mutating the window.
    func moveWindow(_ window: BibleCore.Window, toPosition position: Int) {
        calls.append(.move(window.id, position: position))
    }

    /// Records minimization without mutating the window.
    func minimizeWindow(_ window: BibleCore.Window) { calls.append(.minimize(window.id)) }

    /// Records maximization without mutating the window.
    func maximizeWindow(_ window: BibleCore.Window) { calls.append(.maximize(window.id)) }

    /// Records leaving maximized layout.
    func unmaximize() { calls.append(.unmaximize) }

    /// Records synchronized-scrolling state without mutating the window.
    func setSynchronized(_ window: BibleCore.Window, value: Bool) {
        calls.append(.setSynchronized(window.id, value: value))
    }

    /// Records pin-mode state without mutating the window.
    func setPinMode(_ window: BibleCore.Window, value: Bool) {
        calls.append(.setPinMode(window.id, value: value))
    }

    /// Records synchronization-group selection without mutating the window.
    func changeSyncGroup(_ window: BibleCore.Window, groupNumber: Int) {
        calls.append(.changeSyncGroup(window.id, group: groupNumber))
    }

    /// Records removal without mutating the window.
    func removeWindow(_ window: BibleCore.Window) { calls.append(.remove(window.id)) }
}

/**
 Records effective-weight reads and separator resize writes without mutating persisted models.

 The supplied weight map models `WindowManager`'s effective pin/auto-pin projection. Resize calls
 retain ordering and persistence flags so tests can distinguish transient updates from completion.
 */
private final class RecordingWindowSeparatorResizeTarget: WindowSeparatorResizeTarget {
    /// One adjacent-pane resize delegated by the drag session.
    struct ResizeCall {
        /// Leading or upper pane identifier.
        let firstWindowID: UUID
        /// Effective weight requested for the leading or upper pane.
        let firstWeight: Float
        /// Trailing or lower pane identifier.
        let secondWindowID: UUID
        /// Effective weight requested for the trailing or lower pane.
        let secondWeight: Float
        /// Whether this call must durably commit the gesture result.
        let persist: Bool
    }

    /// Effective weights returned for fixture windows.
    private let effectiveWeights: [UUID: Float]

    /// Ordered identifiers whose effective weights were requested.
    private(set) var effectiveWeightRequests: [UUID] = []

    /// Ordered transient and final resize calls received from the drag session.
    private(set) var resizeCalls: [ResizeCall] = []

    /**
     Creates a recorder with manager-projected fixture weights.

     - Parameter effectiveWeights: Effective weight returned for each fixture window identifier.
     - Side Effects: None.
     - Failure Modes: Missing identifiers return the same `1.0` fallback used by default window data.
     */
    init(effectiveWeights: [UUID: Float]) {
        self.effectiveWeights = effectiveWeights
    }

    /// Records the read and returns the configured effective weight.
    func effectiveLayoutWeight(for window: BibleCore.Window) -> Float {
        effectiveWeightRequests.append(window.id)
        return effectiveWeights[window.id] ?? 1
    }

    /// Records one resize call without mutating either window.
    func resizeWindows(
        _ firstWindow: BibleCore.Window,
        firstWeight: Float,
        _ secondWindow: BibleCore.Window,
        secondWeight: Float,
        persist: Bool
    ) {
        resizeCalls.append(ResizeCall(
            firstWindowID: firstWindow.id,
            firstWeight: firstWeight,
            secondWindowID: secondWindow.id,
            secondWeight: secondWeight,
            persist: persist
        ))
    }
}
