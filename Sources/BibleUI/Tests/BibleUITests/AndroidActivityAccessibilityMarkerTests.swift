import SwiftUI
import XCTest
@testable import BibleUI

/** Work-boundary coverage for optional activity diagnostic projections. */
final class AndroidActivityAccessibilityMarkerTests: XCTestCase {
    /** Disabled diagnostics retain route identity without reading their potentially expensive owner. */
    @MainActor
    func testDisabledDiagnosticProviderIsNeverEvaluated() {
        var evaluations = 0
        let marker = AndroidActivityAccessibilityMarker(
            label: "Bookmarks",
            accessibilityIdentifier: "bookmarkListScreen",
            diagnosticStateProvider: {
                evaluations += 1
                return "expensive owner projection"
            },
            includesDiagnosticState: false,
            surfaceColor: .white
        )

        _ = marker.body
        XCTAssertEqual(evaluations, 0)
        XCTAssertEqual(marker.label, "Bookmarks")
        XCTAssertEqual(marker.accessibilityIdentifier, "bookmarkListScreen")
        XCTAssertNil(marker.accessibilityValue)
    }

    /** Enabled diagnostics copy one owner value instead of recomputing it from the marker's body. */
    @MainActor
    func testEnabledDiagnosticProviderIsCopiedOnce() {
        var evaluations = 0
        let marker = AndroidActivityAccessibilityMarker(
            label: "Bookmarks",
            accessibilityIdentifier: "bookmarkListScreen",
            diagnosticStateProvider: {
                evaluations += 1
                return "rows=1000"
            },
            includesDiagnosticState: true,
            surfaceColor: .white
        )

        _ = marker.body
        _ = marker.body
        XCTAssertEqual(evaluations, 1)
        XCTAssertEqual(marker.accessibilityValue, "rows=1000")
    }

    /** Public initializer and both modifiers guard before evaluating the caller's expression. */
    @MainActor
    func testPublicEntryPointsDeferDiagnosticExpressions() {
        var evaluations = 0
        func projectOwnerState() -> String {
            evaluations += 1
            return "rows=1000"
        }

        _ = AndroidActivityAccessibilityMarker(
            label: "Bookmarks",
            accessibilityIdentifier: "bookmarkListScreen",
            accessibilityValue: projectOwnerState(),
            surfaceColor: .white
        )
        _ = Color.white.androidAccessibilityIdentityMarker(
            label: "Bookmarks",
            accessibilityIdentifier: "bookmarkListScreen",
            accessibilityValue: projectOwnerState(),
            surfaceColor: .white
        )
        _ = Color.white.androidDialogAccessibilityIdentity(
            label: "Choose labels",
            accessibilityIdentifier: "labelDialog",
            accessibilityValue: projectOwnerState()
        )

        XCTAssertEqual(evaluations, UITestRuntimeConfiguration.enablesDetailedAccessibilityExports ? 3 : 0)
    }
}
