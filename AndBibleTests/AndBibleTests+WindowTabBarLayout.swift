import XCTest
@testable import BibleUI

extension AndBibleTests {
    /**
     Protects Android-style compact bottom window buttons on phone-width readers.

     Android uses fixed-size window buttons instead of variable-width text pills, so a normal
     multi-window setup keeps every open window visible in the footer. The tested iPhone width is
     the practical regression case from local Simulator testing: four windows plus the add-window
     button must fit without relying on horizontal scrolling, while larger window counts may reduce
     to the minimum compact size.
     */
    func testFourReaderWindowsAndAddButtonFitInPhoneFooter() {
        let tabWidth = WindowTabBarLayout.tabWidth(availableWidth: 430, windowCount: 4)
        let occupiedWidth = WindowTabBarLayout.occupiedWidth(tabWidth: tabWidth, windowCount: 4)

        XCTAssertLessThanOrEqual(occupiedWidth, 430)
        XCTAssertGreaterThanOrEqual(tabWidth, WindowTabBarLayout.minimumTabWidth)
        XCTAssertLessThanOrEqual(tabWidth, WindowTabBarLayout.maximumTabWidth)
    }

    /**
     Protects the lower bound for dense tab sets.

     The footer should not shrink window buttons below their legible Android-style compact shape
     just to force unusually large tab counts onto one screen. A failure means the layout has moved
     back toward squeezing text until the icon/title/reference identity is no longer readable.
     */
    func testManyReaderWindowsClampToMinimumCompactWidth() {
        let tabWidth = WindowTabBarLayout.tabWidth(availableWidth: 430, windowCount: 8)

        XCTAssertEqual(tabWidth, WindowTabBarLayout.minimumTabWidth)
    }
}
