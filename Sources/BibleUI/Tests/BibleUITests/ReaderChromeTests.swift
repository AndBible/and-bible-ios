import XCTest
import SwiftUI
@testable import BibleUI

/**
 Package-lane coverage for BibleUI reader chrome helpers and view construction.

 These tests exercise the reader header, toolbar action surface, Android-style popup placement,
 overflow menu, Downloads destination routing, and keyboard shortcut command surface without
 requiring the app-host XCTest bundle. Failures indicate the package-owned reader chrome contract
 has drifted from the app-host coverage that previously guarded it.
 */
final class ReaderChromeTests: XCTestCase {
    /**
     Verifies fullscreen iPad readers do not reserve extra chrome inset.

     Android-style reader content should only reserve space for window controls when the iPad scene
     is actually windowed. A failure means fullscreen iPad layouts may get unnecessary leading/top
     padding compared with Android's dense reader surface.
     */
    func testReaderWindowControlsAvoidanceInsetsStayOffForFullscreenIPad() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 834, height: 1194),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets, EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    /**
     Verifies windowed iPad readers reserve the minimum header clearance for system controls.

     The reader header must avoid iPadOS window controls while preserving Android-style density.
     A failure means the document title and toolbar can overlap system chrome or drift too far from
     Android's compact app-bar spacing.
     */
    func testReaderWindowControlsAvoidanceInsetsReserveSpaceForWindowedIPad() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 700, height: 980),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets.top, 10)
        XCTAssertEqual(insets.leading, 56)
        XCTAssertEqual(insets.bottom, 0)
        XCTAssertEqual(insets.trailing, 0)
    }

    /**
     Verifies existing safe-area clearance is credited before adding reader chrome padding.

     Window-control avoidance is a top-up, not a fixed inset. A failure means iPad readers could
     over-pad when the scene already provides partial top or leading safe-area clearance.
     */
    func testReaderWindowControlsAvoidanceInsetsOnlyTopUpMissingSafeAreaClearance() {
        let insets = ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: true,
            sceneSize: CGSize(width: 700, height: 980),
            screenWidth: 834,
            safeAreaInsets: EdgeInsets(top: 36, leading: 20, bottom: 20, trailing: 0)
        )

        XCTAssertEqual(insets.top, 0)
        XCTAssertEqual(insets.leading, 36)
    }

    /**
     Verifies the reader header can build the Bible-mode app-bar surface with injected actions.

     This keeps the SwiftUI chrome construction in the package lane while app-host tests continue
     to cover true application lifecycle wiring. A failure means the Bible-mode header initializer
     or generic toolbar injection contract changed.
     */
    func testBibleReaderDocumentHeaderBuildsBibleModeWithWindowControlInsets() {
        let view = BibleReaderDocumentHeader(
            mode: .bible(
                title: "Genesis 1:1",
                subtitle: "King James Version",
                hasPrevious: false,
                hasNext: true
            ),
            currentReference: "Genesis 1",
            avoidanceInsets: EdgeInsets(top: 10, leading: 56, bottom: 0, trailing: 0),
            onOpenNavigationDrawer: {},
            onNavigatePrevious: {},
            onShowBookChooser: {},
            onNavigateNext: {},
            onReturnFromMyNotes: {},
            onReturnFromStudyPad: {},
            onReturnFromAuxiliary: {},
            onBrowseAuxiliary: {}
        ) {
            EmptyView()
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderDocumentHeader"))
    }

    /**
     Verifies the compact toolbar action surface builds with Strong's and search affordances.

     The contract mirrors Android's compact reader toolbar where Strong's, search, Bible, and
     commentary actions coexist without presenting an app-level scene. A failure means the package
     owned toolbar action initializer drifted from the reader chrome surface.
     */
    func testBibleReaderToolbarActionsBuildCompactStrongsConfiguration() {
        let view = BibleReaderToolbarActions(
            usesCompactToolbar: true,
            preferredSingleAccessory: .search,
            moduleHasStrongs: true,
            strongsIconAssetName: "ToolbarStrongsHebrewLinks",
            strongsMode: StrongsMode.links.rawValue,
            strongsEnabled: true,
            isBibleActive: true,
            isCommentaryActive: false,
            searchEnabled: true,
            speakEnabled: true,
            moduleActionsEnabled: true,
            onShowSearch: {},
            onShowSpeak: {},
            onApplyStrongsMode: { _ in },
            onBibleTap: {},
            onBibleLongPress: {},
            onCommentaryTap: {},
            onCommentaryLongPress: {},
            onShowWorkspaces: {}
        ) {
            EmptyView()
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderToolbarActions"))
    }

    /**
     Verifies Android-style toolbar popups share the same trailing menu rail.

     The Bible quick selector is triggered by the Bible toolbar icon, but Android presents toolbar
     popup menus from the trailing app-bar region. The selector therefore uses the trigger for
     vertical placement only and pins its right edge to the same trailing rail as the overflow menu.
     A failure means the selector can drift toward the middle of the reader on compact screens.
     */
    func testReaderToolbarPopupPlacementPinsQuickSelectorToTrailingMenuRail() {
        let containerSize = CGSize(width: 393, height: 852)
        let safeAreaInsets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let bibleTrigger = CGRect(x: 292, y: 182, width: 24, height: 22)
        let overflowTrigger = CGRect(x: 360, y: 182, width: 24, height: 22)
        let quickSelectorWidth: CGFloat = 232
        let overflowMenuWidth: CGFloat = 236

        let quickPlacement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: bibleTrigger,
            popupWidth: quickSelectorWidth
        )
        let overflowPlacement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: overflowTrigger,
            popupWidth: overflowMenuWidth
        )

        XCTAssertEqual(quickPlacement.offset.width + quickSelectorWidth, 385, accuracy: 0.001)
        XCTAssertEqual(
            quickPlacement.offset.width + quickSelectorWidth,
            overflowPlacement.offset.width + overflowMenuWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(quickPlacement.offset.height, bibleTrigger.maxY + 6, accuracy: 0.001)
    }

    /**
     Verifies toolbar popups expose a bounded viewport height for long Android-style menus.

     Android's `PopupMenu` remains scrollable when many installed modules are available. The iOS
     quick selector must therefore receive a finite height between the toolbar trigger and the
     bottom safe area instead of expanding its full row stack off-screen.
     */
    func testReaderToolbarPopupPlacementBoundsQuickSelectorHeightToVisibleViewport() {
        let containerSize = CGSize(width: 393, height: 852)
        let safeAreaInsets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
        let bibleTrigger = CGRect(x: 292, y: 182, width: 24, height: 22)

        let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: bibleTrigger,
            popupWidth: 232
        )

        XCTAssertEqual(placement.maximumHeight, 600, accuracy: 0.001)
    }

    /**
     Verifies toolbar popup placement stays inside horizontal safe areas.

     Android anchors popup menus to app-bar controls that are already laid out inside system insets.
     The iOS shared popup placement therefore needs to include horizontal safe-area insets when
     computing the trailing rail, especially in landscape where notches and system regions can
     consume non-zero leading or trailing space.
     */
    func testReaderToolbarPopupPlacementRespectsHorizontalSafeAreas() {
        let containerSize = CGSize(width: 852, height: 393)
        let safeAreaInsets = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 47)
        let trigger = CGRect(x: 760, y: 42, width: 24, height: 22)
        let popupWidth: CGFloat = 236

        let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
            containerSize: containerSize,
            safeAreaInsets: safeAreaInsets,
            triggerRect: trigger,
            popupWidth: popupWidth
        )

        XCTAssertEqual(placement.offset.width, 561, accuracy: 0.001)
        XCTAssertEqual(placement.offset.width + popupWidth, 797, accuracy: 0.001)
    }

    /**
     Verifies toolbar popup width calculation cannot feed negative dimensions into SwiftUI layout.

     SwiftUI may report transient zero-width geometry during popup presentation or device rotation.
     The reader uses the bounded width for both placement and `.frame(width:)`, so the shared width
     helper must clamp undersized containers to zero, account for safe-area insets before SwiftUI
     receives a frame width, and preserve normal Android-style popup sizing when enough space
     exists.
     */
    func testReaderToolbarPopupWidthClampHandlesTransientNarrowGeometry() {
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 0,
                preferredWidth: 236,
                maximumWidth: 236
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 8,
                preferredWidth: 236,
                maximumWidth: 236
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 393,
                preferredWidth: max(CGFloat(393) * 0.42, 156),
                maximumWidth: 232
            ),
            CGFloat(165.06),
            accuracy: 0.001
        )
        XCTAssertEqual(
            ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: 200,
                safeAreaInsets: EdgeInsets(top: 0, leading: 80, bottom: 0, trailing: 80),
                preferredWidth: 236,
                maximumWidth: 236
            ),
            24,
            accuracy: 0.001
        )
    }

    /**
     Verifies the reader overflow menu can build with Bible display option rows enabled.

     The state mirrors Android's reader overflow menu controls for night mode, tilt scrolling,
     reverse split mode, pinning, section titles, Strong's, and verse numbers. A failure means the
     package-owned menu surface or state initializer no longer supports that reader contract.
     */
    func testBibleReaderOverflowMenuBuildsWithBibleDisplayOptions() {
        let state = BibleReaderOverflowMenuState(
            isFullScreen: false,
            showsNightModeToggle: true,
            nightMode: false,
            showsTiltToScrollToggle: true,
            tiltToScrollEnabled: false,
            showsReverseSplitModeToggle: true,
            reverseSplitModeEnabled: false,
            windowPinningEnabled: false,
            showsBibleDisplayOptions: true,
            sectionTitlesEnabled: true,
            moduleHasStrongs: true,
            strongsMenuIconAssetName: "ToolbarStrongsHebrew",
            verseNumbersEnabled: true
        )
        let view = BibleReaderOverflowMenu(
            state: state,
            colorScheme: ColorScheme.light,
            onAction: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderOverflowMenu"))
    }

    /**
     Verifies Downloads is modeled as a reader destination rather than a top-level sheet.

     Android opens `Download Documents` as an activity-style route with its own back app bar. The iOS
     reader should therefore expose Downloads through destination routing, leaving `ReaderSheet` for
     genuinely modal reader surfaces.
     */
    func testBibleReaderDownloadsUsesReaderDestinationRoute() {
        XCTAssertEqual(BibleReaderView.ReaderDestination.downloads.rawValue, "downloads")
        XCTAssertEqual(BibleReaderView.ReaderDestination.downloads.id, "downloads")
    }

    /**
     Verifies the reader keyboard shortcut surface builds with all command handlers injected.

     This keeps command-surface coverage in the BibleUI package target while avoiding app launch.
     A failure means the shortcut view's initializer or command wiring contract changed.
     */
    func testBibleReaderKeyboardShortcutsBuildCommandSurface() {
        let view = BibleReaderKeyboardShortcuts(
            onSearch: {},
            onShowBookChooser: {},
            onOpenBookmarks: {},
            onNavigatePrevious: {},
            onNavigateNext: {},
            onCloseClientModal: {},
            onOpenDownloads: {},
            onOpenSettings: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderKeyboardShortcuts"))
    }
}
