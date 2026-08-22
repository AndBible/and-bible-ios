import XCTest
@testable import BibleUI
import SwordKit

/**
 Verifies Android's startup locked-Bible queue independently from SwiftUI and real cipher files.

 These tests protect the behavior that was missing in issue #389: installed locked Bibles are
 snapshotted in registration order, every initial row is processed even after an earlier success,
 cancel/rejection owns an explicit same-row retry decision, and only queue completion returns
 control to the reader's fresh access reconciliation.
 */
final class StartupLockedBibleUnlockQueueTests: XCTestCase {
    /**
     Filters only locked Bibles while preserving exact installed registration order.

     - Setup: Interleaves locked Bibles with commentary, plain, and already-unlocked rows.
     - Expected result: The two locked Bible initials remain in their original relative order.
     - Failure meaning: Startup may prompt for non-Bibles, re-prompt readable content, or diverge
       from Android's `SwordDocumentFacade.bibles.filter { it.isLocked }` snapshot ordering.
     - Side effects: None; immutable metadata is used.
     */
    func testSnapshotFiltersLockedBiblesWithoutSorting() {
        let installedModules = [
            ModuleInfo(
                name: "LOCKED-Z",
                description: "First registered locked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
            ModuleInfo(
                name: "COMMENTARY",
                description: "Locked commentary",
                category: .commentary,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
            ModuleInfo(
                name: "PLAIN",
                description: "Readable Bible",
                category: .bible,
                language: "en"
            ),
            ModuleInfo(
                name: "UNLOCKED",
                description: "Previously unlocked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: true
            ),
            ModuleInfo(
                name: "LOCKED-A",
                description: "Second registered locked Bible",
                category: .bible,
                language: "en",
                isEncrypted: true,
                isUnlocked: false
            ),
        ]

        let queue = StartupLockedBibleUnlockQueue(installedModules: installedModules)

        XCTAssertEqual(queue.lockedBibleModules.map(\.name), ["LOCKED-Z", "LOCKED-A"])
        XCTAssertEqual(queue.currentModule?.name, "LOCKED-Z")
        XCTAssertEqual(queue.presentation, .passphrase)
        XCTAssertFalse(queue.isCompleted)
    }

    /**
     Continues the immutable queue after an accepted credential instead of entering the reader.

     - Setup: Creates two initially locked Bibles and accepts each in turn.
     - Expected result: The first acceptance advances to the second prompt; only the second marks
       the queue complete.
     - Failure meaning: iOS can stop at the first success and skip a later installed locked Bible,
       diverging from Android's full `for` loop.
     - Side effects: None; credential validation belongs to the presenter integration.
     */
    func testAcceptedCredentialStillProcessesEveryInitialLockedBible() {
        var queue = StartupLockedBibleUnlockQueue(
            installedModules: [
                ModuleInfo(
                    name: "FIRST",
                    description: "First",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
                ModuleInfo(
                    name: "SECOND",
                    description: "Second",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
            ]
        )

        queue.acceptCurrentModule()

        XCTAssertEqual(queue.currentModule?.name, "SECOND")
        XCTAssertEqual(queue.presentation, .passphrase)
        XCTAssertFalse(queue.isCompleted)

        queue.acceptCurrentModule()

        XCTAssertNil(queue.currentModule)
        XCTAssertEqual(queue.presentation, .completed)
        XCTAssertTrue(queue.isCompleted)
    }

    /**
     Keeps cancellation/rejection on the same row until the explicit retry decision is resolved.

     - Setup: Opens retry confirmation for the first of two locked Bibles, retries once, then opens
       confirmation again and declines.
     - Expected result: Retry returns to the first module; No advances exactly once to the second.
     - Failure meaning: Cancel can silently skip a credential or retry can duplicate/advance rows,
       breaking Android's nested passphrase loop.
     - Side effects: None; only pure queue state changes.
     */
    func testRetryDecisionRetainsOrAdvancesTheCurrentModuleExplicitly() {
        var queue = StartupLockedBibleUnlockQueue(
            installedModules: [
                ModuleInfo(
                    name: "FIRST",
                    description: "First",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
                ModuleInfo(
                    name: "SECOND",
                    description: "Second",
                    category: .bible,
                    language: "en",
                    isEncrypted: true,
                    isUnlocked: false
                ),
            ]
        )

        queue.requestRetryConfirmation()
        XCTAssertEqual(queue.presentation, .retryConfirmation)
        XCTAssertEqual(queue.currentModule?.name, "FIRST")

        queue.retryCurrentModule()
        XCTAssertEqual(queue.presentation, .passphrase)
        XCTAssertEqual(queue.currentModule?.name, "FIRST")

        queue.requestRetryConfirmation()
        queue.declineRetryForCurrentModule()

        XCTAssertEqual(queue.presentation, .passphrase)
        XCTAssertEqual(queue.currentModule?.name, "SECOND")
        XCTAssertFalse(queue.isCompleted)
    }

    /**
     Guards the reader integration around the pure queue state machine.

     - Setup: Extracts the initial evaluator and post-queue completion function from production.
     - Expected result: Locked-only evaluation retains the queue before setup, while completion
       refreshes controllers and performs one policy evaluation without selecting a queued module.
     - Failure meaning: A refactor can restore the extra-tap-only flow, reconcile after each row, or
       activate the first accepted module before Android's full queue is complete.
     - Side effects: Reads package source only.
     */
    func testReaderStartsQueueBeforeSetupAndReconcilesOnlyAfterCompletion() throws {
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let evaluateSource = try BibleUITestSourceLocator.extractFunction(
            named: "evaluateStartupDownloadPromptIfNeeded",
            from: readerSource
        )
        let completionSource = try BibleUITestSourceLocator.extractFunction(
            named: "completeStartupLockedBibleUnlockQueue",
            from: readerSource
        )
        let queueSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/StartupLockedBibleUnlockQueue.swift"
        )

        XCTAssertTrue(evaluateSource.contains("beginStartupLockedBibleUnlockQueueIfNeeded"))
        XCTAssertTrue(evaluateSource.contains("startupDownloadPromptReason = nil"))
        XCTAssertTrue(completionSource.contains("refreshInstalledModules()"))
        XCTAssertEqual(
            completionSource.components(
                separatedBy: "StartupDocumentSetupPromptPolicy.evaluation"
            ).count - 1,
            1
        )
        XCTAssertFalse(completionSource.contains("switchBibleDocument"))
        XCTAssertFalse(completionSource.contains("selectUnlockedModule"))
        XCTAssertTrue(queueSource.contains("ModuleUnlockActionCoordinator.submit"))
        XCTAssertTrue(queueSource.contains("ModulePickerUnlockDialog"))
        XCTAssertTrue(queueSource.contains("ModulePickerDecisionDialog"))
    }
}
