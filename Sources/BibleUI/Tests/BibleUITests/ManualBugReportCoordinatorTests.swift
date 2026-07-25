import XCTest
@testable import BibleUI

/**
 Covers the state machine that prevents automatic delivery and duplicate manual report launches.

 The tests exercise only deterministic transitions, leaving UIKit and Mail APIs outside the test
surface while proving the same coordinator used by `BibleReaderView` enforces user consent.
 */
final class ManualBugReportCoordinatorTests: XCTestCase {
    /** Cancellation during collection must invalidate the pending completion and leave no handoff. */
    func testCancellationPreventsCollectedReportFromReachingConsent() {
        var coordinator = ManualBugReportCoordinator()

        XCTAssertTrue(coordinator.beginCollection())
        coordinator.cancel()

        XCTAssertFalse(coordinator.completeCollection())
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /** A second launch while collecting must be ignored so there is only one evidence snapshot. */
    func testDuplicateLaunchIsIgnoredWhileCollectionIsActive() {
        var coordinator = ManualBugReportCoordinator()

        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertFalse(coordinator.beginCollection())
        XCTAssertEqual(coordinator.phase, .collecting)
    }

    /** Mail can be requested only after local consent, and unavailable Mail remains explicitly unsent. */
    func testUnavailableMailRequiresConsentAndTransitionsToExportChoice() {
        var coordinator = ManualBugReportCoordinator()

        XCTAssertFalse(coordinator.requestMail(capability: .unavailable))
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertTrue(coordinator.completeCollection())
        XCTAssertTrue(coordinator.requestMail(capability: .unavailable))
        XCTAssertEqual(coordinator.phase, .mailUnavailable)
    }

    /** Every Mail terminal result closes the handoff without treating drafts, cancels, or errors as sends. */
    func testMailSendSaveCancelAndFailureAreAllTerminal() {
        for result in [AddressedMailResult.sent, .saved, .cancelled, .failed] {
            var coordinator = ManualBugReportCoordinator()
            XCTAssertTrue(coordinator.beginCollection())
            XCTAssertTrue(coordinator.completeCollection())
            XCTAssertTrue(coordinator.requestMail(capability: .available))

            coordinator.finishMail(result)

            XCTAssertEqual(coordinator.phase, .idle, "Expected terminal cleanup for \(result)")
        }
    }

    /** ZIP creation failure retains an explicit retry state; a successful retry ends local flow only. */
    func testUnavailableMailExportHandlesFailureAndSuccess() {
        var coordinator = ManualBugReportCoordinator()
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertTrue(coordinator.completeCollection())
        XCTAssertTrue(coordinator.requestMail(capability: .unavailable))

        XCTAssertTrue(coordinator.beginExport())
        coordinator.completeExport(success: false)
        XCTAssertEqual(coordinator.phase, .exportFailed)

        XCTAssertTrue(coordinator.beginExport())
        coordinator.completeExport(success: true)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /**
     Export must end when the ZIP is written, before any share surface presents.

     Share-sheet dismissal paths such as an interactive swipe-down or a Catalyst click-away can
     skip the platform completion callback entirely. If any phase waited for that callback, the
     blocking preparation dialog would persist and every later launch would be rejected. This test
     proves the flow is already idle and re-launchable with no share-surface signal at all.
     */
    func testExportEndsAtZipCreationSoSilentShareDismissalCannotStrandTheFlow() {
        var coordinator = ManualBugReportCoordinator()
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertTrue(coordinator.completeCollection())
        XCTAssertTrue(coordinator.requestMail(capability: .unavailable))
        XCTAssertTrue(coordinator.beginExport())

        coordinator.completeExport(success: true)

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertEqual(coordinator.phase, .collecting)
    }

    /**
     A Mail sheet that closes without any composer delegate result must still end the handoff.

     Some platform dismissal paths never route through the `MFMailComposeViewController` delegate.
     The reader synthesizes a cancelled result on sheet dismissal; this proves that fallback ends
     the phase, keeps the flow re-launchable, and that a late duplicate signal after a delegate
     result already ran is ignored.
     */
    func testMailSheetDismissalWithoutComposerResultEndsHandoffAndAllowsRelaunch() {
        var coordinator = ManualBugReportCoordinator()
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertTrue(coordinator.completeCollection())
        XCTAssertTrue(coordinator.requestMail(capability: .available))

        coordinator.finishMail(.cancelled)

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(coordinator.beginCollection())

        coordinator.finishMail(.cancelled)

        XCTAssertEqual(coordinator.phase, .collecting)
    }

    /** A stale share-surface completion arriving after the flow ended must not corrupt a new launch. */
    func testLateShareCompletionSignalIsIgnoredAfterExportEnded() {
        var coordinator = ManualBugReportCoordinator()
        XCTAssertTrue(coordinator.beginCollection())
        XCTAssertTrue(coordinator.completeCollection())
        XCTAssertTrue(coordinator.requestMail(capability: .unavailable))
        XCTAssertTrue(coordinator.beginExport())
        coordinator.completeExport(success: true)
        XCTAssertTrue(coordinator.beginCollection())

        coordinator.completeExport(success: false)

        XCTAssertEqual(coordinator.phase, .collecting)
    }

    /** Exact 24-hour evidence is allowed; older and future crash diagnostics are excluded. */
    func testCrashDiagnosticExpiryBoundary() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertTrue(RecentCrashDiagnosticRetentionPolicy.isEligible(
            occurrence: now.addingTimeInterval(-RecentCrashDiagnosticRetentionPolicy.maximumAge), now: now
        ))
        XCTAssertFalse(RecentCrashDiagnosticRetentionPolicy.isEligible(
            occurrence: now.addingTimeInterval(-RecentCrashDiagnosticRetentionPolicy.maximumAge - 1), now: now
        ))
        XCTAssertFalse(RecentCrashDiagnosticRetentionPolicy.isEligible(
            occurrence: now.addingTimeInterval(1), now: now
        ))
    }
}
