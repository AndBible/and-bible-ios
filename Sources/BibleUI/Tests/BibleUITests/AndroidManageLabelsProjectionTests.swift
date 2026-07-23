import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Adversarial coverage for the list contract shared by Android Manage Labels modes.

 These tests preserve the category/header sort and the intentionally different filtering rules for
 ASSIGN and WORKSPACE. A screenshot can miss this distinction because both routes show the same
 controls while Android retains selected assignment rows but may filter workspace auto-assign rows.
 */
final class AndroidManageLabelsProjectionTests: XCTestCase {
    /** Verifies Active/Recent/Other headers precede their alphabetized label rows. */
    func testProjectionOrdersMixedHeadersAndLabelsLikeAndroid() {
        let active = Label(name: "Zulu")
        let recent = Label(name: "Beta")
        let other = Label(name: "Alpha")

        let items = AndroidManageLabelsListProjection.items(
            labels: [other, active, recent],
            activeLabelIDs: [active.id],
            recentLabelIDs: [recent.id],
            alwaysVisibleLabelIDs: [active.id],
            searchText: "",
            searchesAnywhereInName: false
        )

        XCTAssertEqual(items, [
            .category(.active),
            .label(active.id),
            .category(.recent),
            .label(recent.id),
            .category(.other),
            .label(other.id),
        ])
    }

    /** Verifies ASSIGN retains selected rows while WORKSPACE applies the same search to active rows. */
    func testProjectionPreservesAndroidModeSpecificSearchRetention() {
        let active = Label(name: "Prayer")
        let other = Label(name: "Worship")

        let assignment = AndroidManageLabelsListProjection.items(
            labels: [active, other],
            activeLabelIDs: [active.id],
            recentLabelIDs: [],
            alwaysVisibleLabelIDs: [active.id],
            searchText: "Wor",
            searchesAnywhereInName: false
        )
        let workspace = AndroidManageLabelsListProjection.items(
            labels: [active, other],
            activeLabelIDs: [active.id],
            recentLabelIDs: [],
            alwaysVisibleLabelIDs: [],
            searchText: "Wor",
            searchesAnywhereInName: false
        )

        XCTAssertTrue(assignment.contains(.label(active.id)))
        XCTAssertTrue(assignment.contains(.label(other.id)))
        XCTAssertFalse(workspace.contains(.label(active.id)))
        XCTAssertTrue(workspace.contains(.label(other.id)))
    }

    /** Verifies the shared Ab* control switches from anchored to contains matching. */
    func testProjectionSupportsAnchoredAndContainsNameModes() {
        let label = Label(name: "Daily Prayer")

        let anchored = AndroidManageLabelsListProjection.items(
            labels: [label],
            activeLabelIDs: [],
            recentLabelIDs: [],
            alwaysVisibleLabelIDs: [],
            searchText: "Prayer",
            searchesAnywhereInName: false
        )
        let contains = AndroidManageLabelsListProjection.items(
            labels: [label],
            activeLabelIDs: [],
            recentLabelIDs: [],
            alwaysVisibleLabelIDs: [],
            searchText: "Prayer",
            searchesAnywhereInName: true
        )

        XCTAssertFalse(anchored.contains(.label(label.id)))
        XCTAssertTrue(contains.contains(.label(label.id)))
    }
}
