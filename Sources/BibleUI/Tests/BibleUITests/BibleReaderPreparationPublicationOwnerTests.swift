import XCTest
@testable import BibleUI

/** Behavioral contracts for explicit queued-bridge and synchronous outward publication. */
@MainActor
final class BibleReaderPreparationPublicationOwnerTests: XCTestCase {
    func testQueuedBridgeRejectsStaleDestinationBeforeAnyMutation() {
        let current = destination(generation: 2)
        let owner = BibleReaderPreparationPublicationOwner { current }
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: destination(generation: 1),
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in effects.append("validate"); return true },
            isSourceCurrentAroundBridge: { _ in effects.append("source"); return true },
            queueBridge: { _ in effects.append("queue"); return true },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .stale(.settle))
        XCTAssertTrue(effects.isEmpty)
    }

    func testQueuedBridgeOmitsAbsentSelectionAndCommitsAfterAcceptedQueue() {
        let destination = destination(generation: 3)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared(42),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { _ in effects.append("owner"); return true },
            queueBridgePrerequisites: { _ in effects.append("prerequisites") },
            isSourceCurrentAroundBridge: { _ in
                effects.append("source")
                return true
            },
            queueBridge: { _ in effects.append("queue"); return true },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .accepted)
        XCTAssertEqual(effects, ["owner", "prerequisites", "source", "queue", "source", "render"])
    }

    func testRejectedQueuedBridgePreservesSelectedIntentWithoutRenderedCommit() {
        let destination = destination(generation: 4)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { _ in effects.append("owner"); return true },
            selectedIntent: .init(
                commit: { _ in effects.append("selected") },
                isCurrentAfterCommit: { _ in effects.append("selected-owner"); return true }
            ),
            isSourceCurrentAroundBridge: { _ in effects.append("source"); return true },
            queueBridge: { _ in effects.append("queue"); return false },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .bridgeRejected)
        XCTAssertEqual(effects, ["owner", "selected", "selected-owner", "source", "queue"])
    }

    func testSelectionPersistenceSupersessionPreventsBridgeQueue() {
        var current = destination(generation: 5)
        let captured = current
        let owner = BibleReaderPreparationPublicationOwner { current }
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: captured,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in true },
            selectedIntent: .init(
                commit: { _ in
                    effects.append("persist")
                    current = self.destination(generation: 6)
                },
                isCurrentAfterCommit: { _ in effects.append("reauthorize"); return true }
            ),
            isSourceCurrentAroundBridge: { _ in effects.append("source"); return true },
            queueBridge: { _ in effects.append("queue"); return true },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .stale(.settle))
        XCTAssertEqual(effects, ["persist"])
    }

    func testPostSelectionCallbackSourceInvalidationPreventsBridgeQueue() {
        let destination = destination(generation: 7)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var sourceIsCurrent = true
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in sourceIsCurrent },
            selectedIntent: .init(
                commit: { _ in effects.append("selected") },
                isCurrentAfterCommit: { _ in sourceIsCurrent }
            ),
            postSelectionCallback: .init(
                commit: { _ in
                    effects.append("callback")
                    sourceIsCurrent = false
                },
                isCurrentAfterCommit: { _ in sourceIsCurrent }
            ),
            isSourceCurrentAroundBridge: { _ in effects.append("source"); return true },
            queueBridge: { _ in effects.append("queue"); return true },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .stale(.requestFreshCurrent))
        XCTAssertEqual(effects, ["selected", "callback"])
    }

    func testConcurrentSourceInvalidationDuringBridgeQueueIsTerminal() {
        let destination = destination(generation: 8)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var sourceIsCurrent = true
        var effects: [String] = []

        let disposition = owner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in true },
            isSourceCurrentAroundBridge: { _ in
                effects.append("source")
                return sourceIsCurrent
            },
            queueBridge: { _ in
                effects.append("queue")
                sourceIsCurrent = false
                return true
            },
            commitAcceptedRender: { _ in effects.append("render") }
        )

        XCTAssertEqual(disposition, .dispatchedStale)
        XCTAssertEqual(effects, ["source", "queue", "source"])
    }

    func testOutwardCallbackSupersessionIsRevalidatedWithoutRetry() {
        var current = destination(generation: 9)
        let captured = current
        let owner = BibleReaderPreparationPublicationOwner { current }
        var effects: [String] = []

        let disposition = owner.publishOutward(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: captured,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in effects.append("validate"); return true },
            route: { _ in
                effects.append("route")
                current = self.destination(generation: 10)
            }
        )

        XCTAssertEqual(disposition, .dispatchedStale)
        XCTAssertEqual(effects, ["validate", "route"])
    }

    func testOutwardCallbackSourceInvalidationIsRevalidatedWithoutRetry() {
        let destination = destination(generation: 11)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var sourceIsCurrent = true
        var effects: [String] = []

        let disposition = owner.publishOutward(
            BibleReaderDocumentPreparationOutcome.prepared("prepared"),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { _ in effects.append("validate"); return sourceIsCurrent },
            route: { _ in
                effects.append("route")
                sourceIsCurrent = false
            }
        )

        XCTAssertEqual(disposition, .dispatchedStale)
        XCTAssertEqual(effects, ["validate", "route", "validate"])
    }

    func testFailureAuthorizationAndCancellationRemainDistinctWithoutEffects() {
        let destination = destination(generation: 12)
        let owner = BibleReaderPreparationPublicationOwner { destination }
        var effects: [String] = []

        func publish(
            _ outcome: BibleReaderDocumentPreparationOutcome<String>
        ) -> BibleReaderPreparationPublicationDisposition {
            owner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: .requestFreshCurrent,
                isCurrent: { _ in effects.append("owner"); return true },
                isSourceCurrentAroundBridge: { _ in effects.append("source"); return true },
                queueBridge: { _ in effects.append("queue"); return true },
                commitAcceptedRender: { _ in effects.append("render") }
            )
        }

        XCTAssertEqual(publish(.phaseFailed), .failed(.settle))
        XCTAssertEqual(publish(.authorizationRejected), .stale(.requestFreshCurrent))
        XCTAssertEqual(publish(.cancelled), .cancelled)
        XCTAssertTrue(effects.isEmpty)
    }

    private func destination(generation: UInt64) -> BibleReaderPreparationDestination {
        BibleReaderPreparationDestination(
            generation: generation,
            paneID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            workspaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
    }
}
