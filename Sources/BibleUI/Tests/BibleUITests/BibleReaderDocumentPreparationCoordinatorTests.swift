// BibleReaderDocumentPreparationCoordinatorTests.swift -- Reader request ownership races

import Foundation
import SwiftData
import XCTest
@testable import BibleCore
import SwordKit
@testable import BibleUI
@testable import BibleView

/** Behavioral coverage for asynchronous preparation ownership and callback settlement. */
final class BibleReaderDocumentPreparationCoordinatorTests: XCTestCase {
    /** Source-dependent annotation capture returns to main before pure worker encoding resumes. */
    @MainActor
    func testOwnerCaptureRunsOnMainBetweenProjectionAndEncoding() async {
        let phases = LockedPreparationValue<[BibleReaderDocumentPreparationPhase]>([])
        let enrichmentOffMain = LockedPreparationValue(false)
        let encodedOffMain = LockedPreparationValue(false)
        let settled = expectation(description: "owner-captured request settles")
        let coordinator = makeCoordinator { phase, _, _ in
            phases.withValue { $0.append(phase) }
        }

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "generic-key"),
            captureSource: { _ in "source" },
            project: { $0 + "-projected" },
            captureOwner: { projected in
                XCTAssertTrue(Thread.isMainThread)
                return projected + "-owner"
            },
            enrichSource: { projected, owner in
                enrichmentOffMain.withValue { $0 = !Thread.isMainThread }
                return "\(projected)|\(owner)|enriched"
            },
            encode: { projected, owner, enriched in
                encodedOffMain.withValue { $0 = !Thread.isMainThread }
                return "\(projected)|\(owner)|\(enriched)"
            },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected owner-captured preparation to succeed")
                }
                XCTAssertEqual(
                    result,
                    "source-projected|source-projected-owner|source-projected|source-projected-owner|enriched"
                )
                settled.fulfill()
            }
        )

        await fulfillment(of: [settled], timeout: 2)
        XCTAssertTrue(enrichmentOffMain.value)
        XCTAssertTrue(encodedOffMain.value)
        XCTAssertEqual(
            phases.value,
            [
                .sourceCapture, .projection, .ownerCapture, .sourceEnrichment, .encoding,
                .publication,
            ]
        )
    }

    /** A coalesced caller replaces stale owner authorization without repeating source work. */
    @MainActor
    func testOwnerCaptureCoalescingUsesLatestEquivalentAuthorization() async {
        let queue = DispatchQueue(label: "BibleReaderDocumentPreparationCoordinatorTests-latest-owner")
        queue.suspend()
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: queue)
        let key = makeKey(content: "equivalent-owner")
        let sourceCount = LockedPreparationValue(0)
        let firstSettled = expectation(description: "stale caller settles")
        let latestSettled = expectation(description: "latest caller receives prepared result")
        var intent = 1

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in
                sourceCount.withValue { $0 += 1 }
                return "source"
            },
            project: { $0 + "-projected" },
            captureOwner: { $0 + "-owner" },
            enrichSource: { "\($0)|\($1)|enriched" },
            encode: { _, _, enriched in enriched },
            isAuthorized: { intent == 1 },
            completion: { outcome in
                guard case .authorizationRejected = outcome else {
                    return XCTFail("Expected stale coalesced caller authorization to be rejected")
                }
                firstSettled.fulfill()
            }
        )
        intent = 2
        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in
                XCTFail("Equivalent owner request repeated source capture")
                return "unexpected"
            },
            project: { $0 },
            captureOwner: { $0 },
            enrichSource: { "\($0)|\($1)|enriched" },
            encode: { _, _, enriched in enriched },
            isAuthorized: { intent == 2 },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected latest coalesced caller to receive prepared content")
                }
                XCTAssertEqual(result, "source-projected|source-projected-owner|enriched")
                latestSettled.fulfill()
            }
        )

        queue.resume()
        await fulfillment(of: [firstSettled, latestSettled], timeout: 2)
        XCTAssertEqual(sourceCount.value, 1)
    }

    /**
     Verifies equivalent replacement requests share preparation and both receive the same result.

     - Side effects: Runs one operation on an isolated worker queue and awaits two main callbacks.
     - Failure meaning: Duplicate navigation can repeat native extraction or lose one caller.
     */
    @MainActor
    func testEquivalentRequestsCoalesceOnePreparationAndSettleEveryCaller() async {
        let coordinator = makeCoordinator()
        let key = makeKey(content: "Gen.1")
        let sourceEntered = DispatchSemaphore(value: 0)
        let releaseSource = DispatchSemaphore(value: 0)
        let sourceCount = LockedPreparationValue(0)
        let first = expectation(description: "first completion")
        let second = expectation(description: "coalesced completion")
        var results: [String] = []

        let firstSubmission = coordinator.submitReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: {
                sourceCount.withValue { $0 += 1 }
                sourceEntered.signal()
                _ = releaseSource.wait(timeout: .now() + 2)
                return "source"
            },
            project: { $0 + "-projected" },
            encode: { $0 + "-encoded" },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let value) = outcome else {
                    return XCTFail("Expected first equivalent request to succeed")
                }
                results.append(value)
                first.fulfill()
            }
        )
        XCTAssertEqual(sourceEntered.wait(timeout: .now() + 2), .success)
        let secondSubmission = coordinator.submitReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: {
                sourceCount.withValue { $0 += 1 }
                return "unexpected"
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let value) = outcome else {
                    return XCTFail("Expected coalesced request to receive prepared content")
                }
                results.append(value)
                second.fulfill()
            }
        )

        guard case .started(let requestID) = firstSubmission else {
            return XCTFail("Expected the first request to start")
        }
        XCTAssertEqual(secondSubmission, .coalesced(requestID: requestID))
        releaseSource.signal()
        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertEqual(sourceCount.value, 1)
        XCTAssertEqual(results, ["source-projected-encoded", "source-projected-encoded"])
    }

    /**
     Verifies a new replacement cancels an older native result before the old capture finishes.

     - Side effects: Holds the first worker operation at a semaphore, submits a replacement, then
       releases and awaits both callbacks.
     - Failure meaning: Slow older navigation can overwrite the latest reader request.
     */
    @MainActor
    func testSupersededNativeWorkSettlesCancelledAndCannotPublish() async {
        let coordinator = makeCoordinator()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "old request cancelled")
        let latest = expectation(description: "latest request published")
        var oldWasCancelled = false
        var latestResult: String?

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "Gen.1"),
            captureSource: {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
                return "old"
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected superseded native work to report cancellation")
                }
                oldWasCancelled = true
                cancelled.fulfill()
            }
        )
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "Exod.1"),
            captureSource: { "latest" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected latest replacement to succeed")
                }
                latestResult = result
                latest.fulfill()
            }
        )
        releaseFirst.signal()

        await fulfillment(of: [cancelled, latest], timeout: 2)
        XCTAssertTrue(oldWasCancelled)
        XCTAssertEqual(latestResult, "latest")
    }

    /**
     A cancelled source loop stops before a second bounded read and releases the SWORD runtime lane.

     The first read is held until a distinct replacement cancels the operation. Releasing that one
     read must let the cancellation query end the old capture, after which the queued Bible capture
     starts and publishes. No elapsed-time threshold or retry participates in the ordering proof.
     */
    @MainActor
    func testCancellableOwnerCaptureStopsOldReadLoopAndReleasesSwordLane() async throws {
        let moduleRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reader-preparation-cancellable-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))
        let coordinator = makeCoordinator(attributes: .concurrent)
        let firstReadEntered = DispatchSemaphore(value: 0)
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let replacementAttemptedLane = DispatchSemaphore(value: 0)
        let oldSettled = expectation(description: "old capture cancelled")
        let latestCaptureEntered = expectation(description: "replacement capture entered")
        let latestSettled = expectation(description: "replacement published")
        let oldReadCount = LockedPreparationValue(0)
        let oldProjectionCount = LockedPreparationValue(0)
        let latestEnteredNativeLane = LockedPreparationValue(false)

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "slow-commentary"),
            captureSource: { cancellation -> String? in
                manager.performRenderOperation(settings: []) {
                    for index in 0..<3 {
                        guard !cancellation.isCancelled else { return nil }
                        oldReadCount.withValue { $0 += 1 }
                        if index == 0 {
                            firstReadEntered.signal()
                            _ = releaseFirstRead.wait(timeout: .now() + 2)
                        }
                    }
                    return "stale-commentary"
                }
            },
            project: { value in
                oldProjectionCount.withValue { $0 += 1 }
                return value
            },
            captureOwner: { _ in "old-owner" },
            enrichSource: { value, _ in value },
            encode: { value, _, _ in value },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected the old source loop to settle as cancelled")
                }
                oldSettled.fulfill()
            }
        )
        XCTAssertEqual(firstReadEntered.wait(timeout: .now() + 2), .success)

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "replacement-bible"),
            captureSource: { _ in
                replacementAttemptedLane.signal()
                return manager.performRenderOperation(settings: []) {
                    latestEnteredNativeLane.withValue { $0 = true }
                    latestCaptureEntered.fulfill()
                    return "current-bible"
                }
            },
            project: { $0 },
            captureOwner: { _ in "current-owner" },
            enrichSource: { value, _ in value },
            encode: { value, _, _ in value },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let value) = outcome else {
                    return XCTFail("Expected the replacement Bible capture to publish")
                }
                XCTAssertEqual(value, "current-bible")
                latestSettled.fulfill()
            }
        )
        XCTAssertEqual(replacementAttemptedLane.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(latestEnteredNativeLane.value)
        releaseFirstRead.signal()

        await fulfillment(
            of: [oldSettled, latestCaptureEntered, latestSettled],
            timeout: 2
        )
        XCTAssertEqual(oldReadCount.value, 1)
        XCTAssertEqual(oldProjectionCount.value, 0)
    }

    /**
     Verifies replacement cancellation settles both pending infinite-scroll directions explicitly.

     - Side effects: Blocks two independent worker lanes, cancels them through a replacement, then
       releases every worker and awaits three callbacks.
     - Failure meaning: Vue can retain an orphaned bridge callback or commit stale loaded bounds.
     */
    @MainActor
    func testReplacementSettlesPendingAppendAndPrependCallbacks() async {
        let coordinator = makeCoordinator(attributes: .concurrent)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let prepend = expectation(description: "prepend settled")
        let append = expectation(description: "append settled")
        let replacement = expectation(description: "replacement settled")
        var cancelledScrollCount = 0

        for (scope, completion) in [
            (BibleReaderDocumentPreparationScope.prepend, prepend),
            (.append, append),
        ] {
            coordinator.submitReportingOutcome(
                scope: scope,
                key: makeKey(content: String(describing: scope)),
                captureSource: {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                    return "stale-scroll"
                },
                project: { $0 },
                encode: { $0 },
                isAuthorized: { true },
                completion: { outcome in
                    guard case .cancelled = outcome else {
                        return XCTFail("Expected replacement to cancel pending scroll work")
                    }
                    cancelledScrollCount += 1
                    completion.fulfill()
                }
            )
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "new-page"),
            captureSource: { "new-page" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared = outcome else {
                    return XCTFail("Expected replacement preparation to succeed")
                }
                replacement.fulfill()
            }
        )
        release.signal()
        release.signal()

        await fulfillment(of: [prepend, append, replacement], timeout: 2)
        XCTAssertEqual(cancelledScrollCount, 2)
    }

    /**
     Verifies the publication boundary rechecks authorization and records all phase correlations.

     - Side effects: Runs one isolated operation and captures small diagnostic phase values.
     - Failure meaning: A removed/relocked source can publish, or performance evidence loses request
       correlation across capture, projection, encoding, and publication.
     */
    @MainActor
    func testAuthorizationIsRecheckedAtPublicationAndPhasesShareRequestIdentity() async {
        let phases = LockedPreparationValue<[
            (BibleReaderDocumentPreparationPhase, UInt64, BibleReaderDocumentPreparationKey)
        ]>([])
        let coordinator = makeCoordinator { phase, requestID, key in
            phases.withValue { $0.append((phase, requestID, key)) }
        }
        let key = makeKey(content: "Gen.1")
        let settled = expectation(description: "unauthorized result settled")
        var authorizationWasRejected = false

        let submission = coordinator.submitReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { "captured" },
            project: { $0 + "-projected" },
            encode: { $0 + "-encoded" },
            isAuthorized: { false },
            completion: { outcome in
                guard case .authorizationRejected = outcome else {
                    return XCTFail("Expected publication authorization rejection")
                }
                authorizationWasRejected = true
                settled.fulfill()
            }
        )
        await fulfillment(of: [settled], timeout: 2)

        guard case .started(let requestID) = submission else {
            return XCTFail("Expected request to start")
        }
        XCTAssertTrue(authorizationWasRejected)
        XCTAssertEqual(phases.value.map(\.0), [
            .sourceCapture, .projection, .encoding, .publication,
        ])
        XCTAssertTrue(phases.value.allSatisfy { $0.1 == requestID && $0.2 == key })
    }

    /**
     Verifies cancellation before a queued operation begins skips every expensive worker phase.

     - Side effects: Holds the serial worker ahead of the request, cancels it, and drains the queue.
     - Failure meaning: Superseded work can still enter native capture or consume projection/encoding.
     */
    @MainActor
    func testCancelledQueuedWorkSkipsCaptureProjectionAndEncoding() async {
        let queue = DispatchQueue(label: "cancelled-reader-preparation")
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        queue.async {
            blockerEntered.signal()
            _ = releaseBlocker.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(blockerEntered.wait(timeout: .now() + 2), .success)

        let phases = LockedPreparationValue<[BibleReaderDocumentPreparationPhase]>([])
        let captureCount = LockedPreparationValue(0)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: queue,
            phaseObserver: { phase, _, _ in phases.withValue { $0.append(phase) } }
        )
        let settled = expectation(description: "cancelled callback")
        var wasCancelled = false
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "queued"),
            captureSource: {
                captureCount.withValue { $0 += 1 }
                return "unexpected"
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected queued request cancellation")
                }
                wasCancelled = true
                settled.fulfill()
            }
        )
        coordinator.cancelAll()
        releaseBlocker.signal()
        let drained = expectation(description: "worker drained")
        queue.async { drained.fulfill() }

        await fulfillment(of: [settled, drained], timeout: 2)
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(captureCount.value, 0)
        XCTAssertEqual(phases.value, [])
    }

    /**
     Verifies a request submitted by a cancellation callback supersedes the outer replacement.

     - Side effects: Cancels blocked work; its callback synchronously submits a third request.
     - Failure meaning: The outer submit can overwrite reentrant work or leave its callback pending.
     */
    @MainActor
    func testReentrantCancellationSubmissionRemainsNewestAndSettlesOuterRequest() async {
        let coordinator = makeCoordinator(attributes: .concurrent)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let oldSettled = expectation(description: "old cancelled")
        let outerSettled = expectation(description: "outer cancelled")
        let reentrantSettled = expectation(description: "reentrant published")
        var outerWasCancelled = false
        var reentrantResult: String?

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "old"),
            captureSource: {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
                return "old"
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected old request cancellation")
                }
                oldSettled.fulfill()
                coordinator.submitReportingOutcome(
                    scope: .replacement,
                    key: self.makeKey(content: "reentrant"),
                    captureSource: { "reentrant" },
                    project: { $0 },
                    encode: { $0 },
                    isAuthorized: { true },
                    completion: { outcome in
                        guard case .prepared(let result) = outcome else {
                            return XCTFail("Expected reentrant request to succeed")
                        }
                        reentrantResult = result
                        reentrantSettled.fulfill()
                    }
                )
            }
        )
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "outer"),
            captureSource: { "outer" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected outer request to be superseded")
                }
                outerWasCancelled = true
                outerSettled.fulfill()
            }
        )
        releaseFirst.signal()

        await fulfillment(of: [oldSettled, outerSettled, reentrantSettled], timeout: 2)
        XCTAssertTrue(outerWasCancelled)
        XCTAssertEqual(reentrantResult, "reentrant")
    }

    /**
     Verifies a coalesced callback cannot publish stale output after an earlier callback navigates.

     - Side effects: Coalesces two callers, then the first completion submits a newer replacement.
     - Failure meaning: Later callbacks from one completed operation can overwrite newer navigation.
     */
    @MainActor
    func testCoalescedCallbacksRecheckCancellationBetweenDeliveries() async {
        let coordinator = makeCoordinator()
        let sourceEntered = DispatchSemaphore(value: 0)
        let releaseSource = DispatchSemaphore(value: 0)
        let first = expectation(description: "first old delivery")
        let second = expectation(description: "second old caller settled")
        let latest = expectation(description: "latest delivery")
        var firstResult: String?
        var latestResult: String?

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "same"),
            captureSource: {
                sourceEntered.signal()
                _ = releaseSource.wait(timeout: .now() + 2)
                return "old"
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected first coalesced callback to receive prepared content")
                }
                firstResult = result
                first.fulfill()
                coordinator.submitReportingOutcome(
                    scope: .replacement,
                    key: self.makeKey(content: "same"),
                    captureSource: { "latest" },
                    project: { $0 },
                    encode: { $0 },
                    isAuthorized: { true },
                    completion: { outcome in
                        guard case .prepared(let result) = outcome else {
                            return XCTFail("Expected replacement submitted from callback to succeed")
                        }
                        latestResult = result
                        latest.fulfill()
                    }
                )
            }
        )
        XCTAssertEqual(sourceEntered.wait(timeout: .now() + 2), .success)
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "same"),
            captureSource: { "unexpected" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected remaining coalesced callback to observe cancellation")
                }
                second.fulfill()
            }
        )
        releaseSource.signal()

        await fulfillment(of: [first, second, latest], timeout: 2)
        XCTAssertEqual(firstResult, "old")
        XCTAssertEqual(latestResult, "latest")
    }

    /**
     Verifies every noncancelled nil phase settles and releases the lane for an exact-key retry.

     - Side effects: Runs capture, projection, and encoding failure cases on isolated coordinators.
     - Failure meaning: A failed phase can strand a callback or make later equivalent work coalesce
       into an operation that will never complete.
     */
    @MainActor
    func testNilPhaseSettlesOnceAndAllowsSameKeyRetry() async {
        for failingPhase in [
            BibleReaderDocumentPreparationPhase.sourceCapture,
            .projection,
            .encoding,
        ] {
            let coordinator = makeCoordinator()
            let key = makeKey(content: "retry-after-\(failingPhase.rawValue)")
            let failed = expectation(description: "\(failingPhase.rawValue) settled")
            var failureCount = 0
            coordinator.submitReportingOutcome(
                scope: .replacement,
                key: key,
                captureSource: { failingPhase == .sourceCapture ? nil : "captured" },
                project: { value -> String? in
                    failingPhase == .projection ? nil : value
                },
                encode: { value -> String? in
                    failingPhase == .encoding ? nil : value
                },
                isAuthorized: { true },
                completion: { outcome in
                    guard case .phaseFailed = outcome else {
                        return XCTFail("Expected \(failingPhase.rawValue) phase failure")
                    }
                    failureCount += 1
                    failed.fulfill()
                }
            )
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertEqual(failureCount, 1)

            let retried = expectation(description: "\(failingPhase.rawValue) retry")
            var retryResult: String?
            let retrySubmission = coordinator.submitReportingOutcome(
                scope: .replacement,
                key: key,
                captureSource: { "retry" },
                project: { $0 },
                encode: { $0 },
                isAuthorized: { true },
                completion: { outcome in
                    guard case .prepared(let result) = outcome else {
                        return XCTFail("Expected same-key retry to succeed")
                    }
                    retryResult = result
                    retried.fulfill()
                }
            )
            guard case .started = retrySubmission else {
                return XCTFail("Expected same-key work to restart after \(failingPhase.rawValue) failure")
            }
            await fulfillment(of: [retried], timeout: 2)
            XCTAssertEqual(retryResult, "retry")
        }
    }

    /** A nil source-enrichment result settles once and releases equivalent work for retry. */
    @MainActor
    func testNilSourceEnrichmentSettlesOnceAndAllowsSameKeyRetry() async {
        let coordinator = makeCoordinator()
        let key = makeKey(content: "retry-after-source-enrichment")
        let failed = expectation(description: "nil enrichment settles")
        var failureCount = 0

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in "captured" },
            project: { $0 },
            captureOwner: { _ in "owner" },
            enrichSource: { _, _ -> String? in nil },
            encode: { _, _, enriched in enriched },
            isAuthorized: { true },
            completion: { outcome in
                guard case .phaseFailed = outcome else {
                    return XCTFail("Expected source-enrichment phase failure")
                }
                failureCount += 1
                failed.fulfill()
            }
        )

        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(failureCount, 1)

        let retried = expectation(description: "same-key enrichment retry")
        var retryResult: String?
        let retrySubmission = coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in "retry" },
            project: { $0 },
            captureOwner: { _ in "owner" },
            enrichSource: { source, owner in "\(source)-\(owner)-enriched" },
            encode: { _, _, enriched in enriched },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected source-enrichment retry to succeed")
                }
                retryResult = result
                retried.fulfill()
            }
        )
        guard case .started = retrySubmission else {
            return XCTFail("Expected same-key work to restart after enrichment failure")
        }
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(retryResult, "retry-owner-enriched")
    }

    /** Cancellation retains an active enrichment lease but prevents later encoding/publication. */
    @MainActor
    func testCancellationDuringSourceEnrichmentRetainsLeaseAndSkipsEncoding() async {
        let queue = DispatchQueue(
            label: "reader-preparation-enrichment-lease",
            attributes: .concurrent
        )
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: queue)
        let enrichmentEntered = expectation(description: "source enrichment entered")
        let releaseEnrichment = DispatchSemaphore(value: 0)
        let oldSettled = expectation(description: "enrichment request cancelled")
        let latestSettled = expectation(description: "replacement published")
        let oldEncodingCount = LockedPreparationValue(0)
        var lease: PreparationLease? = PreparationLease()
        weak var weakLease = lease
        var retainedLease = lease

        coordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "enrichment-lease"),
            captureSource: { _ in "captured" },
            project: { $0 },
            captureOwner: { _ in "owner" },
            enrichSource: { [lease = retainedLease] _, _ in
                enrichmentEntered.fulfill()
                _ = releaseEnrichment.wait(timeout: .now() + 2)
                return lease?.value
            },
            encode: { _, _, enriched in
                oldEncodingCount.withValue { $0 += 1 }
                return enriched
            },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected enrichment request cancellation")
                }
                oldSettled.fulfill()
            }
        )
        lease = nil
        retainedLease = nil
        await fulfillment(of: [enrichmentEntered], timeout: 2)

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "replacement"),
            captureSource: { "latest" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .prepared(let result) = outcome else {
                    return XCTFail("Expected replacement preparation to succeed")
                }
                XCTAssertEqual(result, "latest")
                latestSettled.fulfill()
            }
        )
        await fulfillment(of: [oldSettled, latestSettled], timeout: 2)
        XCTAssertNotNil(weakLease)

        releaseEnrichment.signal()
        let drained = expectation(description: "enrichment worker drained")
        queue.async(flags: .barrier) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertEqual(oldEncodingCount.value, 0)
        XCTAssertNil(weakLease)
    }

    /**
     Verifies cancellation settles promptly while a running native capture retains its source lease.

     - Side effects: Holds a lease-owning capture, cancels it, then drains the serial worker.
     - Failure meaning: Cancellation can release a native resource while SWORD/SQLite/EPUB still uses it.
     */
    @MainActor
    func testRunningCaptureRetainsSourceLeaseUntilNativeWorkReturns() async {
        let queue = DispatchQueue(label: "reader-preparation-lease")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: queue)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let settled = expectation(description: "cancelled callback")
        var lease: PreparationLease? = PreparationLease()
        weak var weakLease = lease
        var retainedLease = lease

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "leased"),
            captureSource: { [lease = retainedLease] in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                return lease?.value
            },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { outcome in
                guard case .cancelled = outcome else {
                    return XCTFail("Expected running capture cancellation")
                }
                settled.fulfill()
            }
        )
        lease = nil
        retainedLease = nil
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        coordinator.cancelAll()
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertNotNil(weakLease)

        release.signal()
        let drained = expectation(description: "worker drained")
        queue.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertNil(weakLease)
    }

    /**
     Verifies delimiter-like My Documents fields cannot coalesce different owner requests.

     The two requests would both flatten to `A|B|C` under the former key construction. Suspending
     the worker makes the overlap deterministic: the later structural key must cancel the first
     operation and publish only its own copied value.
     */
    @MainActor
    func testStructuralMyDocumentRequestIdentityPreventsDelimiterCollisionCoalescing() async {
        let worker = DispatchQueue(
            label: "org.andbible.tests.reader-preparation-structural-key"
        )
        worker.suspend()
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let firstIdentity = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: "A|B",
            requestedKey: "C",
            selectedOrdinalRange: nil,
            expectedFragment: nil
        )
        let secondIdentity = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: "A",
            requestedKey: "B|C",
            selectedOrdinalRange: nil,
            expectedFragment: nil
        )
        let firstFlattened = ["A|B", "C"].joined(separator: "|")
        let secondFlattened = ["A", "B|C"].joined(separator: "|")
        XCTAssertEqual(firstFlattened, secondFlattened)
        XCTAssertNotEqual(firstIdentity, secondIdentity)

        func key(
            _ identity: BibleReaderMyDocumentPreparationRequestIdentity
        ) -> BibleReaderDocumentPreparationKey {
            BibleReaderDocumentPreparationKey(
                family: "my-document",
                paneID: nil,
                workspaceID: nil,
                source: .independent,
                contentIdentity: "my-document-request",
                annotationIdentity: .myDocumentRequest(identity)
            )
        }

        let firstSettled = expectation(description: "first request cancelled")
        let secondSettled = expectation(description: "second request published")
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: key(firstIdentity),
            captureSource: { "first-owner" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true }
        ) { outcome in
            guard case .cancelled = outcome else {
                return XCTFail("Expected structurally distinct replacement to cancel first request")
            }
            firstSettled.fulfill()
        }
        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: key(secondIdentity),
            captureSource: { "second-owner" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true }
        ) { outcome in
            guard case .prepared(let value) = outcome else {
                return XCTFail("Expected structurally distinct second request to succeed")
            }
            XCTAssertEqual(value, "second-owner")
            secondSettled.fulfill()
        }
        worker.resume()

        await fulfillment(of: [firstSettled, secondSettled], timeout: 2)
    }

    /** A nil preparation phase remains distinguishable from authorization invalidation. */
    @MainActor
    func testReportingOutcomePreservesPhaseFailureCause() async {
        let coordinator = makeCoordinator()
        let settled = expectation(description: "phase failure reported")

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "phase-failure"),
            captureSource: { () -> String? in nil },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true }
        ) { outcome in
            guard case .phaseFailed = outcome else {
                return XCTFail("Expected phase failure, got \(outcome)")
            }
            settled.fulfill()
        }

        await fulfillment(of: [settled], timeout: 2)
    }

    /** Completed work reports rejected authorization instead of erasing it into a nil result. */
    @MainActor
    func testReportingOutcomePreservesAuthorizationRejectionCause() async {
        let worker = DispatchQueue(label: "reader-preparation-authorization-outcome")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let settled = expectation(description: "authorization rejection reported")
        var authorized = true

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "authorization-rejection"),
            captureSource: { "captured" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { authorized }
        ) { outcome in
            guard case .authorizationRejected = outcome else {
                return XCTFail("Expected authorization rejection, got \(outcome)")
            }
            settled.fulfill()
        }
        authorized = false
        worker.resume()
        workerIsSuspended = false

        await fulfillment(of: [settled], timeout: 2)
    }

    /** Explicit cancellation retains its own terminal cause and never masquerades as invalidation. */
    @MainActor
    func testReportingOutcomePreservesCancellationCause() async {
        let worker = DispatchQueue(label: "reader-preparation-cancellation-outcome")
        worker.suspend()
        var workerIsSuspended = true
        defer { if workerIsSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let settled = expectation(description: "cancellation reported")

        coordinator.submitReportingOutcome(
            scope: .replacement,
            key: makeKey(content: "cancelled-outcome"),
            captureSource: { "captured" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true }
        ) { outcome in
            guard case .cancelled = outcome else {
                return XCTFail("Expected cancellation, got \(outcome)")
            }
            settled.fulfill()
        }
        coordinator.cancelAll()
        worker.resume()
        workerIsSuspended = false

        await fulfillment(of: [settled], timeout: 2)
    }

    /** Creates an isolated coordinator queue with optional passive phase observation. */
    private func makeCoordinator(
        attributes: DispatchQueue.Attributes = [],
        phaseObserver: BibleReaderDocumentPreparationCoordinator.PhaseObserver? = nil
    ) -> BibleReaderDocumentPreparationCoordinator {
        BibleReaderDocumentPreparationCoordinator(
            workerQueue: DispatchQueue(
                label: "BibleReaderDocumentPreparationCoordinatorTests-\(UUID().uuidString)",
                attributes: attributes
            ),
            phaseObserver: phaseObserver
        )
    }

    /** Creates one exact SWORD-backed synthetic request identity. */
    private func makeKey(content: String) -> BibleReaderDocumentPreparationKey {
        BibleReaderDocumentPreparationKey(
            family: "bible",
            paneID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            source: .independent,
            contentIdentity: BibleReaderPreparationExactText(content),
            annotationIdentity: "revision-7"
        )
    }
}

/** Controller integration coverage for request identity and source-work coalescing. */
final class BibleReaderPreparationControllerTests: BibleUISwordFixtureTestCase {
    /** Equivalent chapter reloads share native preparation while only the newest intent publishes. */
    @MainActor
    func testEquivalentBibleReloadsCoalesceAndPublishLatestIntentOnce() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-controller")
        worker.suspend()
        let sourceCaptures = LockedPreparationValue(0)
        let publication = expectation(description: "latest equivalent request publishes")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                if phase == .sourceCapture {
                    sourceCaptures.withValue { $0 += 1 }
                } else if phase == .publication {
                    publication.fulfill()
                }
            }
        )
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )

        controller.loadCurrentContent()
        controller.loadCurrentContent()
        worker.resume()

        await fulfillment(of: [publication], timeout: 3)
        await Task.yield()
        XCTAssertEqual(sourceCaptures.value, 1)
        XCTAssertEqual(
            recordedScripts().filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        let document = try XCTUnwrap(
            bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_documents",
                selection: .last
            ) as? [String: Any]
        )
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["key"] as? String, "Gen.1")
        XCTAssertEqual(document["chapterNumber"] as? Int, 1)
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        XCTAssertEqual(fragment["osisRef"] as? String, "Gen.1")
        XCTAssertTrue(
            try XCTUnwrap(fragment["xml"] as? String).contains("In the beginning"),
            "The accepted emission must contain the captured KJV chapter, not no-content fallback"
        )
    }

    /** A manager authorization refresh rejects suspended bytes and permits a fresh real reload. */
    @MainActor
    func testManagerRefreshRejectsSuspendedBiblePublication() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-manager-refresh")
        worker.suspend()
        let publicationCount = LockedPreparationValue(0)
        let staleSettled = expectation(description: "stale generation settles")
        let freshSettled = expectation(description: "fresh generation publishes")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                guard phase == .publication else { return }
                let count = publicationCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                (count == 1 ? staleSettled : freshSettled).fulfill()
            }
        )
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )

        controller.loadCurrentContent()
        manager.refresh()
        worker.resume()
        await fulfillment(of: [staleSettled], timeout: 3)
        XCTAssertFalse(scripts().contains { $0.contains("emit('add_documents'") })

        controller.loadCurrentContent()
        await fulfillment(of: [freshSettled], timeout: 3)
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents", selection: .last)
                as? [String: Any]
        )
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["key"] as? String, "Gen.1")
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(fragment["xml"] as? String).contains("In the beginning"))
    }

    /** Switching pane and workspace ownership rejects suspended bytes from the prior destination. */
    @MainActor
    func testPaneWorkspaceSwitchRejectsSuspendedBiblePublication() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-pane-switch")
        worker.suspend()
        let publicationCount = LockedPreparationValue(0)
        let staleSettled = expectation(description: "prior pane settles")
        let currentSettled = expectation(description: "current pane publishes")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                guard phase == .publication else { return }
                let count = publicationCount.withValue { value -> Int in
                    value += 1
                    return value
                }
                (count == 1 ? staleSettled : currentSettled).fulfill()
            }
        )
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let firstWorkspace = store.createWorkspace(name: "First")
        let secondWorkspace = store.createWorkspace(name: "Second")
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: firstWorkspace.id).first)
        let secondWindow = try XCTUnwrap(store.windows(workspaceId: secondWorkspace.id).first)
        retainReaderWindowGraph(firstWindow)
        retainReaderWindowGraph(secondWindow)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.activeWindow = firstWindow

        controller.loadCurrentContent()
        controller.activeWindow = secondWindow
        worker.resume()
        await fulfillment(of: [staleSettled], timeout: 3)
        XCTAssertFalse(scripts().contains { $0.contains("emit('add_documents'") })

        controller.loadCurrentContent()
        await fulfillment(of: [currentSettled], timeout: 3)
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents", selection: .last)
                as? [String: Any]
        )
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["key"] as? String, "Gen.1")
        XCTAssertEqual(controller.activeWindow?.id, secondWindow.id)
        XCTAssertEqual(controller.activeWindow?.workspace?.id, secondWorkspace.id)
    }

    /** Owner revision changes rebase preparation instead of publishing its older progress snapshot. */
    @MainActor
    func testProgressRevisionChangeDuringPreparationRebuildsBeforePublication() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-revision")
        let sourceCaptures = LockedPreparationValue(0)
        let encodingCount = LockedPreparationValue(0)
        let firstEncodingStarted = expectation(description: "first encoding begins")
        let releaseFirstEncoding = DispatchSemaphore(value: 0)
        let publications = expectation(description: "stale and rebased requests finish")
        publications.expectedFulfillmentCount = 2
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                if phase == .sourceCapture {
                    sourceCaptures.withValue { $0 += 1 }
                } else if phase == .encoding {
                    let isFirst = encodingCount.withValue { count -> Bool in
                        count += 1
                        return count == 1
                    }
                    if isFirst {
                        firstEncodingStarted.fulfill()
                        _ = releaseFirstEncoding.wait(timeout: .now() + 3)
                    }
                } else if phase == .publication {
                    publications.fulfill()
                }
            }
        )
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.settingsStore = try makeInMemorySettingsStore()

        controller.loadCurrentContent()
        await fulfillment(of: [firstEncodingStarted], timeout: 3)
        let progressStore = try XCTUnwrap(controller.readingProgressStore)
        let genesisIdentity = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
        )
        try progressStore.recordChapterRead(
            bookInitials: "KJV",
            identity: genesisIdentity,
            source: .manual
        )
        XCTAssertEqual(progressStore.chapterReadCount(kjvBookOrdinal: 2, chapter: 1), 1)
        releaseFirstEncoding.signal()

        await fulfillment(of: [publications], timeout: 4)
        await Task.yield()
        let documentScripts = recordedScripts().filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(sourceCaptures.value, 2)
        XCTAssertEqual(documentScripts.count, 1)
        let document = try XCTUnwrap(
            bridgeEmissionPayload(
                from: documentScripts,
                event: "add_documents",
                selection: .last
            ) as? [String: Any]
        )
        XCTAssertEqual(document["chapterReadCount"] as? Int, 1)
    }

    /** Direct note edits with an unchanged timestamp invalidate a suspended prepared document. */
    @MainActor
    func testNoteTextChangeWithoutTimestampRebuildsBeforePublication() async throws {
        try await assertBookmarkOwnerMutationRebases(
            mutate: { bookmark in
                bookmark.notes?.notes = "new direct note"
            },
            verify: { bookmarkObject in
                XCTAssertEqual(bookmarkObject["notes"] as? String, "new direct note")
                XCTAssertEqual(bookmarkObject["offsetRange"] as? [Int], [1, 2])
            }
        )
    }

    /** Direct offset edits with an unchanged timestamp invalidate a suspended prepared document. */
    @MainActor
    func testOffsetChangeWithoutTimestampRebuildsBeforePublication() async throws {
        try await assertBookmarkOwnerMutationRebases(
            mutate: { bookmark in
                bookmark.startOffset = 7
                bookmark.endOffset = 11
            },
            verify: { bookmarkObject in
                XCTAssertEqual(bookmarkObject["notes"] as? String, "old direct note")
                XCTAssertEqual(bookmarkObject["offsetRange"] as? [Int], [7, 11])
            }
        )
    }

    /** Equivalent append calls share extraction while only one advances the loaded chapter bound. */
    @MainActor
    func testEquivalentAppendRequestsCoalesceWithoutReturningDuplicateDocument() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-append")
        let sourceCaptures = LockedPreparationValue(0)
        let publicationCount = LockedPreparationValue(0)
        let initialPublication = expectation(description: "initial Bible publishes")
        let appendPublication = expectation(description: "coalesced append publishes")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                if phase == .sourceCapture {
                    sourceCaptures.withValue { $0 += 1 }
                } else if phase == .publication {
                    publicationCount.withValue { count in
                        count += 1
                        if count == 1 {
                            initialPublication.fulfill()
                        } else if count == 2 {
                            appendPublication.fulfill()
                        }
                    }
                }
            }
        )
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )

        controller.loadCurrentContent()
        await fulfillment(of: [initialPublication], timeout: 3)
        let responseBoundary = recordedScripts().count
        worker.suspend()
        controller.bridge(bridge, requestMoreToEnd: 7401)
        controller.bridge(bridge, requestMoreToEnd: 7402)
        worker.resume()

        await fulfillment(of: [appendPublication], timeout: 3)
        await Task.yield()
        let responses = Array(recordedScripts().dropFirst(responseBoundary)).filter {
            $0.contains("bibleView.response(740")
        }
        XCTAssertEqual(sourceCaptures.value, 2)
        XCTAssertEqual(responses.count, 2)
        XCTAssertTrue(responses.contains { $0.hasPrefix("bibleView.response(7401, {") })
        XCTAssertTrue(responses.contains { $0 == "bibleView.response(7402, null);" })
    }

    /** Runs one suspended-source race against a directly mutated bookmark owner graph. */
    @MainActor
    private func assertBookmarkOwnerMutationRebases(
        mutate: (BibleBookmark) -> Void,
        verify: ([String: Any]) throws -> Void
    ) async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.reader-preparation-bookmark-owner")
        let sourceCaptures = LockedPreparationValue(0)
        let encodingCount = LockedPreparationValue(0)
        let firstEncodingStarted = expectation(description: "first bookmark encoding begins")
        let releaseFirstEncoding = DispatchSemaphore(value: 0)
        let publications = expectation(description: "stale bookmark snapshot and rebase finish")
        publications.expectedFulfillmentCount = 2
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, _ in
                if phase == .sourceCapture {
                    sourceCaptures.withValue { $0 += 1 }
                } else if phase == .encoding {
                    let isFirst = encodingCount.withValue { count -> Bool in
                        count += 1
                        return count == 1
                    }
                    if isFirst {
                        firstEncodingStarted.fulfill()
                        _ = releaseFirstEncoding.wait(timeout: .now() + 3)
                    }
                } else if phase == .publication {
                    publications.fulfill()
                }
            }
        )
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeBookmarkListModelContainer()
        let context = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: context))
        let bookmark = bookmarkService.addBibleBookmark(
            ordinalRange: try XCTUnwrap(
                VerifiedKJVAOrdinalRange(
                    resolvingSourceBookInitials: "KJV",
                    sourceVersification: "KJV",
                    sourceOrdinalStart: 4,
                    sourceOrdinalEnd: 4
                )
            ),
            wholeVerse: false,
            startOffset: 1,
            endOffset: 2
        )
        bookmark.book = "Genesis"
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "old direct note")
        let unchangedTimestamp = Date(timeIntervalSince1970: 1_234_567)
        bookmark.lastUpdatedOn = unchangedTimestamp

        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            bookmarkService: bookmarkService,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )

        controller.loadCurrentContent()
        await fulfillment(of: [firstEncodingStarted], timeout: 3)
        mutate(bookmark)
        XCTAssertEqual(bookmark.lastUpdatedOn, unchangedTimestamp)
        releaseFirstEncoding.signal()

        await fulfillment(of: [publications], timeout: 4)
        await Task.yield()
        let document = try XCTUnwrap(
            bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_documents",
                selection: .last
            ) as? [String: Any]
        )
        let bookmarkObjects = try XCTUnwrap(document["bookmarks"] as? [[String: Any]])
        let bookmarkObject = try XCTUnwrap(bookmarkObjects.first)
        XCTAssertEqual(sourceCaptures.value, 2)
        XCTAssertEqual(
            recordedScripts().filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        try verify(bookmarkObject)
    }
}

/** Source-generation stand-in whose lifetime is observable without touching native resources. */
private final class PreparationLease: @unchecked Sendable {
    let value = "leased-source"
}

/** Small lock-owned value used only by callbacks that intentionally cross test queues. */
private final class LockedPreparationValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}
