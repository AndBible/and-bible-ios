import XCTest
@testable import BibleUI
@testable import SwordKit

/**
 Behavior tests for the encrypted-module submission contract shared by Downloads and the reader
 picker.

 The suite uses recording closures rather than a SWORD fixture so it can prove exact call ordering,
 empty-key suppression, whitespace preservation, and success callback behavior deterministically.
 It mutates no filesystem, repository, or manager state.
 */
final class ModuleUnlockActionCoordinatorTests: XCTestCase {
    /**
     Verifies an empty key is rejected before the manager is invoked.

     A failure would let a disabled/empty prompt mutate module cipher state or refresh installed rows.
     */
    func testEmptyPassphraseDoesNotInvokeManagerOrSuccessWork() {
        var managerCalls = 0
        var successCalls = 0

        let accepted = ModuleUnlockActionCoordinator.submit(
            module: lockedModule,
            cipherKey: "",
            unlockModule: { _, _ in
                managerCalls += 1
                return true
            },
            onAccepted: { successCalls += 1 }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(managerCalls, 0)
        XCTAssertEqual(successCalls, 0)
    }

    /**
     Verifies whitespace is preserved as a potentially valid provider-issued passphrase.

     The manager receives the exact submitted bytes once and may accept them. A failure would
     introduce trimming or blank-key behavior absent from the existing picker contract.
     */
    func testWhitespacePassphraseIsSubmittedUnchangedAndCanBeAccepted() {
        var submitted: (String, String)?
        var successCalls = 0

        let accepted = ModuleUnlockActionCoordinator.submit(
            module: lockedModule,
            cipherKey: "   ",
            unlockModule: { moduleName, cipherKey in
                submitted = (moduleName, cipherKey)
                return true
            },
            onAccepted: { successCalls += 1 }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(submitted?.0, "LOCKED")
        XCTAssertEqual(submitted?.1, "   ")
        XCTAssertEqual(successCalls, 1)
    }

    /**
     Verifies a manager-rejected passphrase remains failed and exposes shared retry feedback.

     A failure would let either consumer refresh after an invalid key or lose Android's visible
     invalid-passphrase response.
     */
    func testRejectedPassphraseDoesNotRunSuccessWorkAndProvidesRetryMessage() {
        var managerCalls = 0
        var successCalls = 0

        let accepted = ModuleUnlockActionCoordinator.submit(
            module: lockedModule,
            cipherKey: "wrong",
            unlockModule: { _, _ in
                managerCalls += 1
                return false
            },
            onAccepted: { successCalls += 1 }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(managerCalls, 1)
        XCTAssertEqual(successCalls, 0)
        XCTAssertFalse(ModuleUnlockActionCoordinator.failureMessage.isEmpty)
    }

    /**
     Verifies an accepted passphrase runs surface-specific refresh/selection work after validation.

     Event ordering proves the shared coordinator cannot report or refresh an unlocked module before
     `SwordManager` accepts and persists the key.
     */
    func testAcceptedPassphraseRunsSuccessWorkAfterManagerAcceptance() {
        var events: [String] = []

        let accepted = ModuleUnlockActionCoordinator.submit(
            module: lockedModule,
            cipherKey: "secret",
            unlockModule: { moduleName, cipherKey in
                events.append("manager:\(moduleName):\(cipherKey)")
                return true
            },
            onAccepted: { events.append("accepted") }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(events, ["manager:LOCKED:secret", "accepted"])
        XCTAssertTrue(ModuleUnlockActionCoordinator.promptTitle(for: lockedModule).contains("LOCKED"))
    }

    /// Locked module fixture shared by the deterministic submission tests.
    private var lockedModule: ModuleInfo {
        ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            isEncrypted: true,
            isUnlocked: false
        )
    }
}
