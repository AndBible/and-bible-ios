import SwiftUI
import UIKit
import XCTest
@testable import BibleUI

/**
 Verifies the shared dialog viewport follows AppCompat's `wrap_content` plus `AT_MOST` contract.

 These tests measure real SwiftUI content through `UIHostingController`; they do not restate the
 height arithmetic in a separate policy. A regression to a flexible maximum-height frame therefore
 fails when a short History/help hierarchy starts consuming the complete viewport again.
 */
@MainActor
final class AndroidDialogViewportLayoutTests: XCTestCase {
    /**
     Verifies a short dialog reports its intrinsic height under a much taller finite proposal.

     - Side effects: creates an in-memory hosting controller without presenting a window.
     - Failure modes: fails if the shared viewport expands to the available height.
     */
    func testShortDialogReportsIntrinsicHeight() {
        let host = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                Rectangle()
                    .frame(height: 120)
            }
        )

        let measured = host.sizeThatFits(in: CGSize(width: 342, height: 700))

        XCTAssertEqual(measured.height, 120, accuracy: 1)
    }

    /**
     Verifies an overflowing dialog is bounded by its parent without an invented fixed-height cap.

     - Side effects: creates two in-memory hosting controllers without presenting windows.
     - Failure modes: fails if overflow escapes the window or retains an iOS-only height ceiling.
     */
    func testOverflowDialogHonorsOnlyParentHeightBound() {
        let parentBoundHost = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                Rectangle()
                    .frame(height: 1_000)
            }
        )
        let tallerWindowHost = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                Rectangle()
                    .frame(height: 1_000)
            }
        )

        let parentBoundSize = parentBoundHost.sizeThatFits(
            in: CGSize(width: 342, height: 500)
        )
        let tallerWindowSize = tallerWindowHost.sizeThatFits(
            in: CGSize(width: 600, height: 1_200)
        )

        XCTAssertEqual(parentBoundSize.height, 500, accuracy: 1)
        XCTAssertEqual(tallerWindowSize.height, 1_000, accuracy: 1)
    }

    /**
     Verifies a one-row History-shaped scaffold remains content-sized like Android's dialog Activity.

     The production History view adds the same 64-point row plus bottom spacing beneath this title
     region. This test intentionally measures the shared host/scaffold contract without SwiftData.

     - Side effects: creates an in-memory hosting controller without presenting a window.
     - Failure modes: fails if History-shaped content consumes most of the viewport.
     */
    func testShortHistoryScaffoldDoesNotExpandToViewportHeight() {
        let host = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                AndroidDialogScaffold(title: "History", showsActionRegion: false) {
                    AndroidAdaptiveDialogScrollView {
                        VStack(spacing: 0) {
                            Text("Daniel 12 KJV")
                                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        }
                        .padding(.bottom, 8)
                    }
                } actions: {
                    EmptyView()
                }
            }
        )

        let measured = host.sizeThatFits(in: CGSize(width: 342, height: 700))

        XCTAssertGreaterThan(measured.height, 64)
        XCTAssertLessThan(measured.height, 220)
    }

    /**
     Verifies a long History-shaped list consumes only the finite dialog viewport and remains valid.

     - Side effects: creates an in-memory hosting controller without presenting a window.
     - Failure modes: fails if adaptive overflow either escapes or collapses inside the viewport.
     */
    func testLongHistoryScaffoldUsesBoundedOverflowHeight() {
        let host = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                AndroidDialogScaffold(title: "History", showsActionRegion: false) {
                    AndroidAdaptiveDialogScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<20, id: \.self) { row in
                                Text("History row \(row)")
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 64,
                                        alignment: .leading
                                    )
                            }
                        }
                        .padding(.bottom, 8)
                    }
                } actions: {
                    EmptyView()
                }
            }
        )

        let measured = host.sizeThatFits(in: CGSize(width: 342, height: 500))

        XCTAssertEqual(measured.height, 500, accuracy: 1)
    }

    /**
     Verifies Android's compact AI Settings help uses natural vertical size when its message fits.

     - Side effects: resolves English localization and creates an in-memory hosting controller.
     - Failure modes: fails if the adaptive message or shared scaffold greedily fills the viewport.
     */
    func testAISettingsHelpUsesNaturalHeightWhenContentFits() {
        let host = UIHostingController(
            rootView: AndroidDialogViewportLayout {
                AndroidFeatureHelpDialogContent(topic: .aiSettings, onDismiss: {})
            }
            .environment(\.locale, Locale(identifier: "en"))
        )

        let measured = host.sizeThatFits(in: CGSize(width: 342, height: 700))

        XCTAssertGreaterThan(measured.height, 180)
        XCTAssertLessThan(measured.height, 600)
    }
}
