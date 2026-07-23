import SwiftUI
import UIKit
import XCTest
@testable import BibleUI

/** Protects topic-filtered full Help from regressing to a full-height custom dialog. */
@MainActor
final class AndroidFullHelpDialogSizingTests: XCTestCase {
    /**
     Verifies Study Pads Help reports the natural height of Android's production Help composition.

     The measured hierarchy is the same title-icon/message/action content supplied to
     `AndroidDialogWindow` in production. English is fixed so copy length remains deterministic.

     - Side effects: resolves localization and creates an in-memory hosting controller.
     - Failure modes: fails if the full Help wrapper or adaptive message fills the viewport.
     */
    func testStudyPadsHelpUsesNaturalHeightWhenContentFits() {
        let host = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                AndroidFullHelpDialogContent(
                    topics: [.studyPads],
                    showsVersion: false,
                    onDismiss: {}
                )
            }
            .environment(\.locale, Locale(identifier: "en"))
        )

        let measured = host.sizeThatFits(in: CGSize(width: 342, height: 700))

        XCTAssertGreaterThan(measured.height, 300)
        XCTAssertLessThan(measured.height, 650)
    }
}
