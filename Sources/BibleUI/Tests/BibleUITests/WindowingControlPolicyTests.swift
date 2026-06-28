import XCTest
@testable import BibleUI

#if os(iOS)
import UIKit

/**
 Package-lane coverage for iPadOS windowing-control policy owned by BibleUI.

 These tests keep the reader window-control behavior outside the app-host bundle while preserving
 the production policy contract used by the application delegate's scene wiring.
 */
final class WindowingControlPolicyTests: XCTestCase {
    /**
     Verifies that the shared policy uses the compact iPadOS 26 window-control style only on iPad.

     Setup:
     - calls the pure policy helper with explicit UIKit interface idioms
     - avoids app delegate or scene lifecycle setup because that wiring remains app-hosted

     Expected result:
     - iPad returns `true`
     - iPhone returns `false`

     Failure meaning:
     - iOS chrome could drift from Android-style reader density on iPad or incorrectly change iPhone
       system window controls.
     */
    func testWindowingControlPolicyUsesMinimalStyleOnlyOnIPad() {
        XCTAssertTrue(
            AndBibleWindowingControlPolicy.shouldUseMinimalStyle(userInterfaceIdiom: .pad)
        )
        XCTAssertFalse(
            AndBibleWindowingControlPolicy.shouldUseMinimalStyle(userInterfaceIdiom: .phone)
        )
    }

    /**
     Verifies the policy's typed style choice preserves the iPad-only minimal-style contract.

     The production scene delegate consumes this enum-like policy result before resolving the private
     UIKit selector. Testing it in BibleUI keeps the behavior package-owned while the app-host bundle
     continues to validate delegate installation.
     */
    func testWindowingControlPolicyChoosesMinimalStyleOnlyOnIPad() {
        XCTAssertEqual(
            AndBibleWindowingControlPolicy.preferredWindowingControlStyleChoice(userInterfaceIdiom: .pad),
            .minimal
        )
        XCTAssertEqual(
            AndBibleWindowingControlPolicy.preferredWindowingControlStyleChoice(userInterfaceIdiom: .phone),
            .automatic
        )
    }

    /**
     Verifies the scene delegate resolves selector names without requiring a live `UIWindowScene`.

     Setup:
     - calls the static selector-choice helper with explicit interface idioms
     - does not exercise `AndBibleApplicationDelegate.sceneConfiguration`, which remains an app-host
       lifecycle test

     Expected result:
     - iPad maps to the minimal selector
     - iPhone maps to the automatic selector

     Failure meaning:
     - the app may ask UIKit for the wrong system window-control style even though the delegate is
       installed correctly.
     */
    func testWindowSceneDelegateSelectorChoiceChoosesMinimalStyleOnlyOnIPad() {
        XCTAssertEqual(
            AndBibleWindowSceneDelegate.preferredWindowingControlStyleSelectorName(userInterfaceIdiom: .pad),
            "minimalStyle"
        )
        XCTAssertEqual(
            AndBibleWindowSceneDelegate.preferredWindowingControlStyleSelectorName(userInterfaceIdiom: .phone),
            "automaticStyle"
        )
    }
}
#endif
