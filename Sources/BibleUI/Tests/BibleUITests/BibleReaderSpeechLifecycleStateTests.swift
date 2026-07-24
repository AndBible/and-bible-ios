import XCTest
@testable import BibleUI

/**
 Contracts for separating first-reader speech setup from repeat destination reactivation.

 The state is exercised synchronously because SwiftUI calls the owning reader's appearance handler
 on the main actor. No simulator, persistence, SWORD data, or external resources are involved.
 */
final class BibleReaderSpeechLifecycleStateTests: XCTestCase {
    /**
     Verifies one reader identity requests heavyweight speech setup only on its first activation.

     A failure means a navigation pop can rerun persisted restoration and callback binding, or a
     newly created reader can skip required initial setup.
     */
    func testInitialSetupIsConsumedExactlyOncePerReaderIdentity() {
        var firstReader = BibleReaderSpeechLifecycleState()

        XCTAssertTrue(firstReader.beginActivation())
        XCTAssertFalse(firstReader.beginActivation())
        XCTAssertFalse(firstReader.beginActivation())
        XCTAssertTrue(firstReader.didPerformInitialSetup)

        var recreatedReader = BibleReaderSpeechLifecycleState()
        XCTAssertTrue(recreatedReader.beginActivation())
    }
}
