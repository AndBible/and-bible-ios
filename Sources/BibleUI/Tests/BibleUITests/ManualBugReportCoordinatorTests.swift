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
