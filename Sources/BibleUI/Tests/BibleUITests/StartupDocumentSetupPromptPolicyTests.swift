import XCTest
@testable import BibleUI

/**
 Verifies the reader startup setup prompt policy independently from the app-host lifecycle.

 These tests protect the Android-parity startup contract: no-Bible setup remains blocking and
 repeatable, while iOS' bundled fallback Bible does not suppress the one-time recommended setup
 entry point. Failures mean first-run users can again lose the discoverable Easy Start/Downloads
 path because module presence and setup completion were conflated.
 */
final class StartupDocumentSetupPromptPolicyTests: XCTestCase {
    /**
     No-Bible module state must take priority over the informational first-run setup marker.

     Android keeps users on its first-download setup surface while no Bible is installed. iOS mirrors
     that as a startup prompt even if the user previously skipped the recommended setup message.
     */
    func testNoBiblePromptTakesPriorityOverHandledFirstRunSetup() {
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: true,
                hasHandledFirstRunSetup: true
            ),
            .noBibleModules
        )
    }

    /**
     A bundled fallback Bible must not count as completing first-run setup.

     Fresh iOS installs include KJV so the reader can render immediately, but issue #320 requires a
     discoverable recommended setup path until the user explicitly enters setup or skips it.
     */
    func testFirstRunSetupPromptAppearsWhenBibleExistsButSetupNotHandled() {
        XCTAssertEqual(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: false,
                hasHandledFirstRunSetup: false
            ),
            .firstRunSetup
        )
    }

    /**
     The startup setup prompt is suppressed after the user has handled first-run setup.

     This keeps the first-run prompt durable and one-time after the user opens setup/downloads or
     explicitly skips it, while leaving the no-Bible prompt covered by the priority test above.
     */
    func testPromptIsSuppressedWhenBibleExistsAndFirstRunSetupHandled() {
        XCTAssertNil(
            StartupDocumentSetupPromptPolicy.promptReason(
                hasNoBibleModules: false,
                hasHandledFirstRunSetup: true
            )
        )
    }
}
