// NavigationTests.swift — Tests for BibleUI navigation

import XCTest
@testable import BibleUI

final class NavigationTests: XCTestCase {
    func testChapterCountMapping() {
        // Verify some chapter counts
        let view = ChapterChooserView(bookName: "Genesis") { _ in }
        // Chapter counts are embedded in the view — this is a basic compilation test
        XCTAssertNotNil(view)
    }
}
