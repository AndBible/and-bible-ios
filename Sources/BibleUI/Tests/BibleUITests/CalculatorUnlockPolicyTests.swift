import XCTest
@testable import BibleUI

/**
 Protects the Calculator product's single exact-PIN authorization boundary.

 The suite exercises the pure policy rather than SwiftUI rendering so large retry counts and
 lifecycle reconstruction remain deterministic. The Calculator UI smoke test separately proves
 the production view stays gated across backgrounding and relaunch.
 */
final class CalculatorUnlockPolicyTests: XCTestCase {
    /** Exact custom PIN input authorizes while wrong, empty, and transformed values do not. */
    func testOnlyExactNonemptyDirectPINAuthorizes() {
        XCTAssertTrue(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "8642",
                configuredPIN: "8642",
                isDirectEntry: true
            )
        )
        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "8641",
                configuredPIN: "8642",
                isDirectEntry: true
            )
        )
        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "",
                configuredPIN: "",
                isDirectEntry: true
            )
        )
        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "",
                configuredPIN: "0",
                isDirectEntry: true
            ),
            "The calculator's initial zero display must not count as entered PIN input."
        )
        XCTAssertTrue(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "0",
                configuredPIN: "0",
                isDirectEntry: true
            )
        )
        XCTAssertTrue(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "08642",
                configuredPIN: "08642",
                isDirectEntry: true
            ),
            "Exact matching must preserve leading zeroes in a configured PIN."
        )
        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "8642",
                configuredPIN: "8642",
                isDirectEntry: false
            ),
            "An arithmetic result equal to the PIN must not authorize access."
        )
        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: " 8642 ",
                configuredPIN: "8642",
                isDirectEntry: true
            ),
            "PIN matching is exact rather than whitespace-normalized."
        )
    }

    /**
     One hundred wrong attempts never create an alternate authorization state.

     Re-evaluating with a fresh call models background/relaunch reconstruction because the policy
     has no stored attempt count. Any success means a retry or lifecycle bypass has returned.
     */
    func testRepeatedWrongAttemptsAndLifecycleReconstructionNeverAuthorize() {
        for _ in 0..<100 {
            XCTAssertFalse(
                CalculatorUnlockPolicy.allowsUnlock(
                    enteredPIN: "0",
                    configuredPIN: "8642",
                    isDirectEntry: true
                )
            )
        }

        XCTAssertFalse(
            CalculatorUnlockPolicy.allowsUnlock(
                enteredPIN: "0",
                configuredPIN: "8642",
                isDirectEntry: true
            ),
            "Reconstructed policy evaluation must remain independent of prior attempts."
        )
    }
}
