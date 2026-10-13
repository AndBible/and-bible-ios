// BibleReaderClientReadyReplayLifecycleTests.swift -- Client-ready publication ownership

import Foundation
import XCTest
@testable import BibleUI
@testable import BibleView

/** Verifies client-ready replay waits for the native work that owns visible-content publication. */
final class BibleReaderClientReadyReplayLifecycleTests: XCTestCase {
    /** Successful and failed replacement settlement both release the retained replay. */
    @MainActor
    func testReplacementSettlementReleasesReplayForSuccessAndFailure() async {
        for succeeds in [true, false] {
            let coordinator = makeCoordinator()
            let settled = expectation(description: "replacement settles")
            let replayed = expectation(description: "client-ready replay runs")

            coordinator.submitReportingOutcome(
                scope: .replacement,
                key: makeKey("settlement-\(succeeds)"),
                captureSource: { succeeds ? "content" : nil },
                project: { $0 },
                encode: { $0 },
                isAuthorized: { true },
                completion: { _ in settled.fulfill() }
            )
            XCTAssertTrue(
                coordinator.deferClientReadyReplayUntilContentWorkSettles {
                    replayed.fulfill()
                }
            )

            await fulfillment(of: [settled, replayed], timeout: 2, enforceOrder: true)
        }
    }

    /** A transient publication retains client-ready replay until its terminal callback finishes. */
    @MainActor
    func testTransientWorkBlocksReplayUntilSettlement() async {
        let worker = DispatchQueue(label: "org.andbible.tests.client-ready-transient")
        worker.suspend()
        var workerSuspended = true
        defer { if workerSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let settled = expectation(description: "transient settles")
        let replayed = expectation(description: "client-ready replay runs")

        submit(on: coordinator, scope: .transient, identity: "transient") {
            settled.fulfill()
        }
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { replayed.fulfill() }
        )
        worker.resume()
        workerSuspended = false

        await fulfillment(of: [settled, replayed], timeout: 2, enforceOrder: true)
    }

    /** Reentrant replacement from a completion keeps the replay behind the new publication owner. */
    @MainActor
    func testReentrantReplacementKeepsReplayDeferredUntilNewWorkSettles() async {
        let coordinator = makeCoordinator()
        let secondEntered = expectation(description: "reentrant replacement entered source capture")
        let releaseSecond = DispatchSemaphore(value: 0)
        let replayed = expectation(description: "client-ready replay runs")
        let secondSettled = expectation(description: "reentrant replacement settles")

        submit(on: coordinator, scope: .replacement, identity: "first") { [self] in
            coordinator.submitReportingOutcome(
                scope: .replacement,
                key: makeKey("second"),
                captureSource: {
                    secondEntered.fulfill()
                    _ = releaseSecond.wait(timeout: .now() + 2)
                    return "content"
                },
                project: { $0 },
                encode: { $0 },
                isAuthorized: { true },
                completion: { _ in secondSettled.fulfill() }
            )
        }
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { replayed.fulfill() }
        )
        await fulfillment(of: [secondEntered], timeout: 2)
        let idleTurn = expectation(description: "queued idle check observes reentrant work")
        DispatchQueue.main.async { idleTurn.fulfill() }
        await fulfillment(of: [idleTurn], timeout: 2)

        releaseSecond.signal()
        await fulfillment(of: [secondSettled, replayed], timeout: 2, enforceOrder: true)
    }

    /** A same-turn replacement submitted after cancelAll remains a blocker for its queued check. */
    @MainActor
    func testCancelAllThenSameTurnReplacementKeepsReplayDeferred() async {
        let worker = DispatchQueue(label: "org.andbible.tests.client-ready-cancel-replace")
        worker.suspend()
        var workerSuspended = true
        defer { if workerSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let firstCancelled = expectation(description: "first replacement cancelled")
        let secondSettled = expectation(description: "new replacement settles")
        let replayed = expectation(description: "client-ready replay runs")

        submit(on: coordinator, scope: .replacement, identity: "cancelled") {
            firstCancelled.fulfill()
        }
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { replayed.fulfill() }
        )
        coordinator.cancelAll()
        submit(on: coordinator, scope: .replacement, identity: "new") {
            secondSettled.fulfill()
        }
        await fulfillment(of: [firstCancelled], timeout: 2)
        let idleTurn = expectation(description: "cancel check observes new replacement")
        DispatchQueue.main.async { idleTurn.fulfill() }
        await fulfillment(of: [idleTurn], timeout: 2)

        worker.resume()
        workerSuspended = false
        await fulfillment(of: [secondSettled, replayed], timeout: 2, enforceOrder: true)
    }

    /** Explicit cancellation removes the pending replay while leaving active work unchanged. */
    @MainActor
    func testCancellingDeferredReplayPreventsSettlementCallback() async {
        let worker = DispatchQueue(label: "org.andbible.tests.client-ready-cancel-replay")
        worker.suspend()
        var workerSuspended = true
        defer { if workerSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let settled = expectation(description: "replacement settles")
        var replayed = false

        submit(on: coordinator, scope: .replacement, identity: "replacement") {
            settled.fulfill()
        }
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { replayed = true }
        )
        coordinator.cancelDeferredClientReadyReplay()
        worker.resume()
        workerSuspended = false
        await fulfillment(of: [settled], timeout: 2)
        let idleTurn = expectation(description: "post-settlement idle check")
        DispatchQueue.main.async { idleTurn.fulfill() }
        await fulfillment(of: [idleTurn], timeout: 2)
        XCTAssertFalse(replayed)
    }

    /** A newer idle ready event supersedes an older replay before its queued idle check executes. */
    @MainActor
    func testIdleReadyEventClearsPreviouslyQueuedReplay() async {
        let worker = DispatchQueue(label: "org.andbible.tests.client-ready-newest-idle")
        worker.suspend()
        var workerSuspended = true
        defer { if workerSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        var oldReplayCount = 0
        var newReplayCount = 0

        submit(on: coordinator, scope: .replacement, identity: "old") {}
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { oldReplayCount += 1 }
        )
        coordinator.cancelAll()
        XCTAssertFalse(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { newReplayCount += 1 }
        )
        newReplayCount += 1
        let idleTurn = expectation(description: "queued old idle check drains")
        DispatchQueue.main.async { idleTurn.fulfill() }
        await fulfillment(of: [idleTurn], timeout: 2)

        XCTAssertEqual(oldReplayCount, 0)
        XCTAssertEqual(newReplayCount, 1)
        worker.resume()
        workerSuspended = false
    }

    /** Incremental cancellation abandons old callbacks but preserves replacement and its replay. */
    @MainActor
    func testIncrementalCancellationPreservesReplacementAndDeferredReplay() async {
        let worker = DispatchQueue(label: "org.andbible.tests.client-ready-incremental")
        worker.suspend()
        var workerSuspended = true
        defer { if workerSuspended { worker.resume() } }
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let replacementSettled = expectation(description: "replacement settles")
        var prependCallbackRan = false
        var appendCallbackRan = false
        let replayed = expectation(description: "client-ready replay runs")

        submit(on: coordinator, scope: .replacement, identity: "replacement") {
            replacementSettled.fulfill()
        }
        submit(on: coordinator, scope: .prepend, identity: "prepend") {
            prependCallbackRan = true
        }
        submit(on: coordinator, scope: .append, identity: "append") {
            appendCallbackRan = true
        }
        XCTAssertTrue(
            coordinator.deferClientReadyReplayUntilContentWorkSettles { replayed.fulfill() }
        )
        coordinator.cancelIncrementalPreparation()
        XCTAssertFalse(prependCallbackRan)
        XCTAssertFalse(appendCallbackRan)
        XCTAssertTrue(coordinator.hasActiveReplacement)

        worker.resume()
        workerSuspended = false
        await fulfillment(of: [replacementSettled, replayed], timeout: 2, enforceOrder: true)
        XCTAssertFalse(prependCallbackRan)
        XCTAssertFalse(appendCallbackRan)
    }

    /** Both emitter overloads report acceptance only when the bridge queues their transaction. */
    func testReplacementEmitterCallbackMatchesTypedAndSerializedBridgeAcceptance() {
        let acceptedBridge = BibleBridge()
        acceptedBridge.javaScriptEvaluationObserver = { _ in }
        var typedAccepted = 0
        let typedEmitter = BibleReaderDocumentReplacementEmitter(
            bridge: acceptedBridge,
            buildInitialConfigJSON: { #"{"initial":true}"# },
            onReplacementAccepted: { typedAccepted += 1 }
        )
        XCTAssertTrue(
            typedEmitter.replace(document: ["key": "Gen.1"], setup: ReaderSetupContentPayload())
        )
        XCTAssertEqual(typedAccepted, 1)

        var serializedAccepted = 0
        let serializedEmitter = BibleReaderDocumentReplacementEmitter(
            bridge: acceptedBridge,
            buildInitialConfigJSON: { #"{"initial":true}"# },
            onReplacementAccepted: { serializedAccepted += 1 }
        )
        XCTAssertTrue(
            serializedEmitter.replace(
                documentJSON: #"{"key":"Gen.2"}"#,
                setup: ReaderSetupContentPayload()
            )
        )
        XCTAssertEqual(serializedAccepted, 1)

        var encodingFailureCallbacks = 0
        let encodingFailureEmitter = BibleReaderDocumentReplacementEmitter(
            bridge: acceptedBridge,
            buildInitialConfigJSON: { #"{"initial":true}"# },
            onReplacementAccepted: { encodingFailureCallbacks += 1 }
        )
        XCTAssertFalse(
            encodingFailureEmitter.replace(
                document: ThrowingReplacementPayload(),
                setup: ReaderSetupContentPayload()
            )
        )
        XCTAssertEqual(encodingFailureCallbacks, 0)

        let rejectedBridge = BibleBridge()
        var rejectedCallbacks = 0
        let rejectedEmitter = BibleReaderDocumentReplacementEmitter(
            bridge: rejectedBridge,
            buildInitialConfigJSON: { #"{"initial":true}"# },
            onReplacementAccepted: { rejectedCallbacks += 1 }
        )
        XCTAssertFalse(
            rejectedEmitter.replace(document: ["key": "Gen.3"], setup: ReaderSetupContentPayload())
        )
        XCTAssertFalse(
            rejectedEmitter.replace(
                documentJSON: #"{"key":"Gen.4"}"#,
                setup: ReaderSetupContentPayload()
            )
        )
        XCTAssertEqual(rejectedCallbacks, 0)
    }

    /** Submits one deterministic string preparation and exposes only its terminal callback. */
    @MainActor
    private func submit(
        on coordinator: BibleReaderDocumentPreparationCoordinator,
        scope: BibleReaderDocumentPreparationScope,
        identity: String,
        completion: @escaping () -> Void
    ) {
        coordinator.submitReportingOutcome(
            scope: scope,
            key: makeKey(identity),
            captureSource: { "content" },
            project: { $0 },
            encode: { $0 },
            isAuthorized: { true },
            completion: { _ in completion() }
        )
    }

    /** Creates an isolated serial worker coordinator for one lifecycle test. */
    @MainActor
    private func makeCoordinator() -> BibleReaderDocumentPreparationCoordinator {
        BibleReaderDocumentPreparationCoordinator(
            workerQueue: DispatchQueue(
                label: "org.andbible.tests.client-ready-replay-\(UUID().uuidString)"
            )
        )
    }

    /** Creates one structurally exact request identity without production source dependencies. */
    private func makeKey(_ identity: String) -> BibleReaderDocumentPreparationKey {
        BibleReaderDocumentPreparationKey(
            family: "client-ready-replay",
            paneID: nil,
            workspaceID: nil,
            source: .independent,
            contentIdentity: BibleReaderPreparationExactText(identity),
            annotationIdentity: "client-ready-revision"
        )
    }
}

/** Typed replacement fixture that fails before a bridge transaction can be queued. */
private struct ThrowingReplacementPayload: Encodable {
    /** Synthetic encoding failure used to verify the emitter's rejection boundary. */
    private struct EncodingFailure: Error {}

    /** Always rejects serialization so no JavaScript replacement can be accepted. */
    func encode(to encoder: Encoder) throws {
        throw EncodingFailure()
    }
}
