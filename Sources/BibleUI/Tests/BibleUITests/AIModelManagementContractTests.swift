import Foundation
import XCTest
@testable import BibleUI

/**
 Contract tests for Android-parity model chooser, editor, and list-row policies.

 Tests exercise pure values only. They render no SwiftUI, access no SwiftData or Keychain state, and
 perform no filesystem or network work. Failure indicates the pushed Models screen can diverge from
 Android before a user action reaches persistence.
 */
final class AIModelManagementContractTests: XCTestCase {
    /**
     Verifies Add does nothing without providers, skips the chooser for one, and opens it for many.

     Failure means the Models toolbar can expose an unusable editor or add unnecessary navigation
     compared with Android's provider-count routing.
     */
    func testAddDestinationMatchesAndroidProviderCountRouting() {
        let firstProviderID = UUID()
        let secondProviderID = UUID()

        XCTAssertNil(AIModelDialog.addDestination(providerIDs: []))
        XCTAssertEqual(
            AIModelDialog.addDestination(providerIDs: [firstProviderID]),
            .editor(providerID: firstProviderID, modelID: nil)
        )
        XCTAssertEqual(
            AIModelDialog.addDestination(providerIDs: [firstProviderID, secondProviderID]),
            .providerChooser
        )
    }

    /**
     Verifies Android's asymmetric add and edit default-model rules.

     Adding selects only when no default exists. Editing can select any model, explicitly clear the
     model that was default when opened, and leave a different current default untouched. Failure
     means checkbox saves can unexpectedly replace or retain the global selection.
     */
    func testDefaultPolicyMatchesAndroidAddAndEditSemantics() {
        let existingDefaultID = UUID()
        let editedModelID = UUID()
        let concurrentlySelectedID = UUID()

        XCTAssertEqual(
            AIModelEditorPolicy.defaultModelIDAfterAdding(
                existingDefaultModelID: nil,
                newModelID: editedModelID
            ),
            editedModelID
        )
        XCTAssertEqual(
            AIModelEditorPolicy.defaultModelIDAfterAdding(
                existingDefaultModelID: existingDefaultID,
                newModelID: editedModelID
            ),
            existingDefaultID
        )
        XCTAssertEqual(
            AIModelEditorPolicy.defaultModelIDAfterEditing(
                modelID: editedModelID,
                currentDefaultModelID: existingDefaultID,
                wasCurrentDefault: false,
                isChecked: true
            ),
            editedModelID
        )
        XCTAssertNil(
            AIModelEditorPolicy.defaultModelIDAfterEditing(
                modelID: editedModelID,
                currentDefaultModelID: concurrentlySelectedID,
                wasCurrentDefault: true,
                isChecked: false
            )
        )
        XCTAssertEqual(
            AIModelEditorPolicy.defaultModelIDAfterEditing(
                modelID: editedModelID,
                currentDefaultModelID: concurrentlySelectedID,
                wasCurrentDefault: false,
                isChecked: false
            ),
            concurrentlySelectedID
        )
    }

    /**
     Verifies editable custom prices reject invalid values and display with Android's precision.

     Failure means malformed or non-finite rates can enter persistence, or model rows can show a
     different sub-cent and cumulative-cost representation from Android.
     */
    func testPriceSanitizationAndFormattingMatchAndroid() {
        XCTAssertEqual(AIModelEditorPolicy.sanitizedPrice("1.25"), 1.25, accuracy: 0.000_001)
        XCTAssertEqual(AIModelEditorPolicy.sanitizedPrice("-4"), 0)
        XCTAssertEqual(AIModelEditorPolicy.sanitizedPrice("nan"), 0)
        XCTAssertEqual(AIModelEditorPolicy.sanitizedPrice("invalid"), 0)
        XCTAssertEqual(AIModelPricePresentation.compact(0.009), "< $0.01")
        XCTAssertEqual(AIModelPricePresentation.compact(1.25), "$1.25")
        XCTAssertEqual(AIModelPricePresentation.cumulativeCost(0.009), "$0.009")
        XCTAssertEqual(AIModelPricePresentation.cumulativeCost(1.25), "$1.25")
    }

    /**
     Verifies list rows expose Android's default/supported badges and exact two-line cost summary.

     The fixture uses a catalog-supported prefixed model and a positive sub-cent cumulative cost.
     Failure means the pushed screen can hide support/default state, duplicate provider information,
     or omit Android's persisted input/output and cumulative pricing.
     */
    func testRowPresentationMatchesAndroidBadgesSummaryAndCumulativeCost() {
        let row = AIModelListRowPresentation(
            modelID: "openai/gpt-5.4-mini",
            providerName: "OpenAI",
            inputPricePerMillion: 0.75,
            outputPricePerMillion: 4.50,
            cumulativeCost: 0.009,
            isDefault: true
        )

        XCTAssertTrue(row.isDefault)
        XCTAssertTrue(row.isSupported)
        XCTAssertEqual(row.modelID, "openai/gpt-5.4-mini")
        XCTAssertEqual(
            row.providerModelAndPricingSummary,
            "OpenAI — openai/gpt-5.4-mini ($0.75/$4.50)"
        )
        XCTAssertEqual(row.cumulativeCostText, "$0.009")

        let noCostRow = AIModelListRowPresentation(
            modelID: "community/unknown",
            providerName: "Custom",
            inputPricePerMillion: 0,
            outputPricePerMillion: 0,
            cumulativeCost: 0,
            isDefault: false
        )
        XCTAssertFalse(noCostRow.isSupported)
        XCTAssertEqual(noCostRow.providerModelAndPricingSummary, "Custom — community/unknown")
        XCTAssertNil(noCostRow.cumulativeCostText)
    }
}
