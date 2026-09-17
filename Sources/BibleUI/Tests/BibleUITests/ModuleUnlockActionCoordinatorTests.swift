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
    func testRejectedPassphraseDoesNotRunSuccessWork() {
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
    }

    /** Rejection and cancellation retain the same module until the explicit retry decision. */
    func testSessionRetainsExactModuleAcrossRejectedCancelledAndRetryPhases() {
        var submitted: [(String, String)] = []
        var session = ModuleUnlockSession(module: lockedModule)

        XCTAssertNil(
            session.submit { _, _ in
                XCTFail("Empty input must not reach the manager")
                return true
            }
        )
        XCTAssertEqual(session.presentation, .retryConfirmation)
        session.retry()
        XCTAssertEqual(session.presentation, .passphrase)

        session.cipherKey = "wrong"
        XCTAssertNil(session.submit { module, key in
            submitted.append((module, key))
            return false
        })
        XCTAssertEqual(submitted.map(\.0), ["LOCKED"])
        XCTAssertEqual(submitted.map(\.1), ["wrong"])
        XCTAssertEqual(session.presentation, .retryConfirmation)
        XCTAssertEqual(session.module.name, "LOCKED")
        XCTAssertTrue(session.cipherKey.isEmpty)

        XCTAssertNil(
            session.submit { _, _ in
                XCTFail("A stale submit must not run")
                return true
            }
        )
        session.retry()
        XCTAssertEqual(session.presentation, .passphrase)
        session.cipherKey = "discarded"
        session.cancelPassphrase()
        XCTAssertEqual(session.presentation, .retryConfirmation)
        XCTAssertTrue(session.cipherKey.isEmpty)
        session.retry()
        XCTAssertEqual(session.presentation, .passphrase)
        XCTAssertEqual(submitted.count, 1)
    }

    /** Acceptance and decline are terminal, so stale actions cannot repeat manager or owner work. */
    func testSessionTerminalOutcomesSettleOnce() {
        var managerCalls = 0
        var accepted = ModuleUnlockSession(module: lockedModule)
        accepted.cipherKey = "secret"
        XCTAssertEqual(
            accepted.submit { _, _ in
                managerCalls += 1
                return true
            },
            .accepted
        )
        XCTAssertEqual(accepted.presentation, .completed(.accepted))
        accepted.cipherKey = "later"
        XCTAssertNil(
            accepted.submit { _, _ in
                managerCalls += 1
                return true
            }
        )
        accepted.cancelPassphrase()
        XCTAssertEqual(managerCalls, 1)
        XCTAssertEqual(accepted.presentation, .completed(.accepted))

        var declined = ModuleUnlockSession(module: lockedModule)
        declined.cancelPassphrase()
        XCTAssertEqual(declined.decline(), .declined)
        XCTAssertEqual(declined.presentation, .completed(.declined))
        XCTAssertNil(declined.decline())
    }

    /** About covers the editor without validation and then returns to the same session. */
    func testSessionInformationPresentationKeepsPassphraseOwnership() {
        var session = ModuleUnlockSession(
            module: lockedModule,
            initialCipherKey: "persisted-key"
        )
        XCTAssertEqual(session.cipherKey, "persisted-key")
        session.prepareForInformation()

        XCTAssertEqual(session.presentation, .information)
        XCTAssertEqual(session.module.name, "LOCKED")
        XCTAssertTrue(session.cipherKey.isEmpty)
        session.resumeAfterInformation()
        XCTAssertEqual(session.presentation, .passphrase)
        XCTAssertEqual(session.cipherKey, "persisted-key")
    }

    /** Explicit rekey retry restores Android's persisted `book.unlockKey` prompt value. */
    func testSessionRetryRestoresPersistedPromptKey() {
        var session = ModuleUnlockSession(
            module: lockedModule,
            initialCipherKey: "persisted-key"
        )
        session.cipherKey = "wrong-replacement"
        XCTAssertNil(session.submit { _, _ in false })
        XCTAssertEqual(session.presentation, .retryConfirmation)
        XCTAssertTrue(session.cipherKey.isEmpty)

        session.retry()
        XCTAssertEqual(session.presentation, .passphrase)
        XCTAssertEqual(session.cipherKey, "persisted-key")
    }

    /** Accepted, Cancel, and About commands captured by an old presenter cannot cross owners. */
    func testOwnedSessionBoundaryRejectsStaleCommandsAfterReplacementAndDismissal() {
        var first = ModuleUnlockSession(module: lockedModule)
        let staleID = first.id
        first.cipherKey = "old"

        let replacementModule = ModuleInfo(
            name: "REPLACEMENT",
            description: "Replacement Bible",
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            isEncrypted: true,
            isUnlocked: false
        )
        var owner: ModuleUnlockSession? = ModuleUnlockSession(
            module: replacementModule,
            initialCipherKey: "current"
        )
        var managerCalls = 0
        XCTAssertFalse(
            ModuleUnlockSession.mutateOwnedSession(&owner, expectedID: staleID) { stale in
                _ = stale.submit { _, _ in
                    managerCalls += 1
                    return true
                }
            }
        )
        XCTAssertEqual(owner?.module.name, "REPLACEMENT")
        XCTAssertEqual(owner?.cipherKey, "current")
        XCTAssertEqual(owner?.presentation, .passphrase)
        XCTAssertEqual(managerCalls, 0)

        XCTAssertFalse(
            ModuleUnlockSession.mutateOwnedSession(&owner, expectedID: staleID) { stale in
                stale.cancelPassphrase()
            }
        )
        XCTAssertFalse(
            ModuleUnlockSession.mutateOwnedSession(&owner, expectedID: staleID) { stale in
                stale.prepareForInformation()
            }
        )
        XCTAssertEqual(owner?.module.name, "REPLACEMENT")
        XCTAssertEqual(owner?.cipherKey, "current")
        XCTAssertEqual(owner?.presentation, .passphrase)

        let replacementID = owner?.id
        owner = nil
        if let replacementID {
            XCTAssertFalse(
                ModuleUnlockSession.mutateOwnedSession(&owner, expectedID: replacementID) { stale in
                    stale.cancelPassphrase()
                    stale.prepareForInformation()
                }
            )
        } else {
            XCTFail("Expected replacement session identity")
        }
        XCTAssertNil(owner)
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
