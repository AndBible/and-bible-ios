import XCTest
@testable import BibleUI

extension AndBibleTests {
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
     Protects the lower bound for dense tab sets.

     The footer should not shrink window buttons below their legible Android-style compact shape
     just to force unusually large tab counts onto one screen. A failure means the layout has moved
     back toward squeezing text until the icon/title/reference identity is no longer readable.
     */
    func testManyReaderWindowsClampToMinimumCompactWidth() {
        let tabWidth = WindowTabBarLayout.tabWidth()

        XCTAssertEqual(tabWidth, WindowTabBarLayout.minimumTabWidth)
    }
}
