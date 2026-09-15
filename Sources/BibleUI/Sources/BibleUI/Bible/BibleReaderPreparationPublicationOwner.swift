// BibleReaderPreparationPublicationOwner.swift -- Main-queue reader publication ownership

import Foundation

/** Exact destination identity captured when one prepared reader request begins. */
struct BibleReaderPreparationDestination: Equatable, Hashable, Sendable {
    /// Monotonic controller-owned content intent.
    let generation: UInt64
    /// Window pane receiving the result, when persistence owns one.
    let paneID: UUID?
    /// Workspace owning the destination pane.
    let workspaceID: UUID?
}

/** Explicit caller policy returned when prepared work cannot publish. */
enum BibleReaderPreparationFailurePolicy: Equatable, Sendable {
    /// Settle the operation without changing current selected or rendered state.
    case settle
    /// Let the caller submit one fresh request after checking its family-specific source state.
    case requestFreshCurrent
}

/** Result of the main-queue owner publication transaction. */
enum BibleReaderPreparationPublicationDisposition: Equatable, Sendable {
    /// A preparation phase failed before it produced a result.
    case failed(BibleReaderPreparationFailurePolicy)
    /// Destination, source, or exact owner state changed before an accepted outward side effect.
    case stale(BibleReaderPreparationFailurePolicy)
    /// Scheduling cancellation settled without changing selected or rendered state.
    case cancelled
    /// Selected intent committed, but the local bridge did not accept the prepared replacement.
    case bridgeRejected
    /// A queued or outward side effect was accepted before destination or source invalidation.
    case dispatchedStale
    /// The prepared side effect and its permitted local render state committed in order.
    case accepted
}

/** One synchronous native mutation paired with the exact authorization required after it. */
struct BibleReaderPreparationSynchronousMutation<Result> {
    /// Native selected-state, persistence, or explicit callback side effect.
    let commit: (Result) -> Void
    /// Exact owner authorization evaluated after the synchronous side effect returns.
    let isCurrentAfterCommit: (Result) -> Bool
}

/**
 Owns main-queue destination validation and selected-versus-rendered publication order.

 `BibleReaderDocumentPreparationCoordinator` remains the sole scheduler. This owner has no queue,
 request registry, cancellation, coalescing, or retry behavior. Family adapters supply exact source
 and owner validation plus their direct selected and rendered state effects.

 Local bridge publication and outward native routing are separate contracts. A local bridge call
 queues JavaScript and cannot synchronously reenter the reader through WebKit. An outward route is a
 synchronous native callback whose accepted side effect must never reuse the pre-route retry policy.
 */
final class BibleReaderPreparationPublicationOwner {
    typealias DestinationProvider = () -> BibleReaderPreparationDestination

    private let currentDestination: DestinationProvider

    /** Creates one publication owner over controller-owned destination state. */
    init(currentDestination: @escaping DestinationProvider) {
        self.currentDestination = currentDestination
    }

    /// Captures the current request destination without retaining a SwiftData model.
    func captureDestination() -> BibleReaderPreparationDestination {
        dispatchPrecondition(condition: .onQueue(.main))
        return currentDestination()
    }

    /// Whether an earlier request still belongs to the exact current pane and intent.
    func isCurrent(_ destination: BibleReaderPreparationDestination) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return currentDestination() == destination
    }

    /**
     Publishes one local document or Promise response through the queued WebKit boundary.

     Exact owner state is checked before any mutation and again after selected intent when that
     mutation exists. Bridge prerequisites do not synchronously call native reader code in the
     production WebKit path. Native source generations can still change on other threads, so the
     caller supplies a source-only authorization immediately before and after JavaScript is queued.

     The post-enqueue check preserves native generations that can change off-main without treating
     WebKit as synchronously reentrant. A later installed-source change is handled by the explicit
     lifecycle reconciliation path; a Promise response that was already queued is settled exactly
     once and never uses a pre-enqueue retry policy.
     */
    func publishQueuedBridge<Result: Sendable>(
        _ outcome: BibleReaderDocumentPreparationOutcome<Result>,
        destination: BibleReaderPreparationDestination,
        failurePolicy: BibleReaderPreparationFailurePolicy,
        stalePolicy: BibleReaderPreparationFailurePolicy,
        isCurrent: (Result) -> Bool,
        selectedIntent: BibleReaderPreparationSynchronousMutation<Result>? = nil,
        postSelectionCallback: BibleReaderPreparationSynchronousMutation<Result>? = nil,
        queueBridgePrerequisites: ((Result) -> Void)? = nil,
        isSourceCurrentAroundBridge: (Result) -> Bool,
        queueBridge: (Result) -> Bool,
        commitAcceptedRender: (Result) -> Void
    ) -> BibleReaderPreparationPublicationDisposition {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.isCurrent(destination) else { return .stale(.settle) }
        let result: Result
        switch outcome {
        case .prepared(let prepared): result = prepared
        case .phaseFailed: return .failed(failurePolicy)
        case .authorizationRejected: return .stale(stalePolicy)
        case .cancelled: return .cancelled
        }
        guard isCurrent(result) else { return .stale(stalePolicy) }

        if let selectedIntent {
            selectedIntent.commit(result)
            guard self.isCurrent(destination) else { return .stale(.settle) }
            guard selectedIntent.isCurrentAfterCommit(result) else {
                return .stale(stalePolicy)
            }
        }

        if let postSelectionCallback {
            postSelectionCallback.commit(result)
            guard self.isCurrent(destination) else { return .stale(.settle) }
            guard postSelectionCallback.isCurrentAfterCommit(result) else {
                return .stale(stalePolicy)
            }
        }

        queueBridgePrerequisites?(result)
        guard isSourceCurrentAroundBridge(result) else {
            return .stale(stalePolicy)
        }
        guard queueBridge(result) else { return .bridgeRejected }
        guard isSourceCurrentAroundBridge(result) else { return .dispatchedStale }
        commitAcceptedRender(result)
        return .accepted
    }

    /**
     Publishes one prepared result to a synchronous native destination owner.

     The callback receives only a fully current result. It can synchronously supersede the source
     reader, so destination and source ownership are checked after it returns. A stale callback is
     terminal because its outward side effect was already accepted and must not be retried.
     */
    func publishOutward<Result: Sendable>(
        _ outcome: BibleReaderDocumentPreparationOutcome<Result>,
        destination: BibleReaderPreparationDestination,
        failurePolicy: BibleReaderPreparationFailurePolicy,
        stalePolicy: BibleReaderPreparationFailurePolicy,
        isCurrent: (Result) -> Bool,
        route: (Result) -> Void
    ) -> BibleReaderPreparationPublicationDisposition {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.isCurrent(destination) else { return .stale(.settle) }
        let result: Result
        switch outcome {
        case .prepared(let prepared): result = prepared
        case .phaseFailed: return .failed(failurePolicy)
        case .authorizationRejected: return .stale(stalePolicy)
        case .cancelled: return .cancelled
        }
        guard isCurrent(result) else { return .stale(stalePolicy) }
        route(result)
        guard self.isCurrent(destination) else { return .dispatchedStale }
        guard isCurrent(result) else { return .dispatchedStale }
        return .accepted
    }
}
