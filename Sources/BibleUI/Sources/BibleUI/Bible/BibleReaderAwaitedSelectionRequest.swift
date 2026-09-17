import Foundation

/**
 Owns one awaited reader selection from its first admitted attempt through retry and replay.

 The request identity stays stable while ``claim(generation:cancellation:)`` advances the
 controller generation owned by the current attempt. Cancellation is cooperative: it records the
 request as cancelled and invokes the most recent cancellation callback, which must revalidate the
 returned claim on the controller's main actor before changing pane state. Completion is one-shot
 and resumes at most one waiter; late callbacks and queued cancellation actions become no-ops.

 The lock protects continuation and cancellation handoff across Swift task and preparation-worker
 queues. No controller, bridge, or persistence state is touched by this type itself.
 */
final class BibleReaderAwaitedSelectionRequest: @unchecked Sendable {
    /** Stable request identity paired with the generation of one admitted attempt. */
    struct Claim: Equatable, Sendable {
        /// Stable identity shared by every attempt and replay belonging to the request.
        let requestID: UUID
        /// Controller content generation owned by the most recently admitted attempt.
        let generation: UInt64
    }

    private let lock = NSLock()
    private let requestID = UUID()
    private var generation: UInt64?
    private var terminalDisposition: BibleReaderPreparationPublicationDisposition?
    private var cancellationRequested = false
    private var selectedKey: String?
    private var cancellationAction: (@Sendable (Claim) -> Void)?
    private var continuation:
        CheckedContinuation<BibleReaderPreparationPublicationDisposition, Never>?

    /**
     Waits for the request's exactly-once terminal disposition.

     - Returns: The first disposition supplied to ``complete(_:)``.
     - Side effects: Stores and later resumes one checked continuation. Cancelling the surrounding
       task records cancellation and invokes the latest installed attempt callback.
     - Failure modes: A second concurrent waiter is a programmer error and traps in debug builds;
       callers create one request per awaiting API invocation.
     - Concurrency: Safe from any queue. Cancellation may precede attempt admission; the next claim
       immediately receives a cancellation callback in that case.
     */
    func wait() async -> BibleReaderPreparationPublicationDisposition {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let terminalDisposition {
                    lock.unlock()
                    continuation.resume(returning: terminalDisposition)
                    return
                }
                precondition(self.continuation == nil, "Awaited selection requests support one waiter")
                self.continuation = continuation
                let shouldCancel = cancellationRequested
                let claim = generation.map { Claim(requestID: requestID, generation: $0) }
                let cancellationAction = self.cancellationAction
                lock.unlock()
                if shouldCancel, let claim, let cancellationAction {
                    cancellationAction(claim)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    /**
     Advances ownership to one newly admitted controller generation.

     - Parameters:
       - generation: Content-intent generation synchronously allocated for the attempt or replay.
       - cancellation: Callback that queues main-actor cancellation and revalidates its claim.
     - Returns: The stable request identity paired with `generation`, or `nil` after terminal state.
     - Side effects: Replaces the prior attempt's cancellation callback. If cancellation arrived
       earlier, invokes the new callback after releasing the lock.
     - Failure modes: Terminal requests reject new claims without invoking the callback.
     - Concurrency: A queued callback for an older generation remains safe because ``owns(_:)``
       rejects it after this method advances the generation.
     */
    @discardableResult
    func claim(
        generation: UInt64,
        cancellation: @escaping @Sendable (Claim) -> Void
    ) -> Claim? {
        lock.lock()
        guard terminalDisposition == nil else {
            lock.unlock()
            return nil
        }
        self.generation = generation
        cancellationAction = cancellation
        let shouldCancel = cancellationRequested
        let claim = Claim(requestID: requestID, generation: generation)
        lock.unlock()
        if shouldCancel {
            cancellation(claim)
        }
        return claim
    }

    /**
     Tests whether a queued action still belongs to the request's live current attempt.

     - Parameter claim: Stable request and attempt generation captured by the queued action.
     - Returns: `true` only before terminal completion and for the latest admitted generation.
     - Side effects: None beyond lock acquisition.
     - Failure modes: None; stale, future, and terminal claims return `false`.
     - Concurrency: Safe from any queue and intended for a final main-actor cancellation check.
     */
    func owns(_ claim: Claim) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalDisposition == nil
            && requestID == claim.requestID
            && generation == claim.generation
    }

    /**
     Tests whether one generation is the request's live current attempt.

     - Parameter generation: Controller generation captured by a preparation completion.
     - Returns: `true` only before terminal completion and when the generation matches the latest
       claim admitted for this stable request.
     - Side effects: Acquires and releases the request lock.
     - Failure modes: Unclaimed, stale, future, and terminal generations return `false`.
     - Concurrency: Safe from any queue; controller publication uses it with controller identity and
       generation checks to prevent an older retry callback from settling a newer attempt.
     */
    func owns(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalDisposition == nil && self.generation == generation
    }

    /**
     Records the exact key committed by this request's selected-intent callback.

     - Parameter key: Request-owned dictionary, general-book, map, EPUB, or My Documents key.
     - Side effects: Replaces the request-local receipt before terminal completion.
     - Failure modes: Commits arriving after terminal completion are ignored.
     - Concurrency: Safe from any queue; callers should invoke this only from the selected-intent
       callback whose source authorization has just been revalidated.
     */
    func recordCommittedKey(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard terminalDisposition == nil else { return }
        selectedKey = key
    }

    /**
     Returns the exact selected key recorded for this request.

     - Returns: Request-owned committed key, or `nil` when selected intent never committed.
     - Side effects: None beyond lock acquisition.
     - Failure modes: None. A matching prior controller selection is never inferred as this receipt.
     - Concurrency: Safe before or after terminal completion.
     */
    func committedKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return selectedKey
    }

    /**
     Completes the request once and releases its retained cancellation and continuation state.

     - Parameter disposition: Final publication result returned to the awaiting caller.
     - Returns: `true` only for the callback that won terminal ownership.
     - Side effects: Resumes the stored waiter after releasing the lock.
     - Failure modes: Later completion attempts are ignored and return `false`.
     - Concurrency: Safe from any queue; continuation resumption occurs exactly once.
     */
    @discardableResult
    func complete(_ disposition: BibleReaderPreparationPublicationDisposition) -> Bool {
        lock.lock()
        guard terminalDisposition == nil else {
            lock.unlock()
            return false
        }
        terminalDisposition = disposition
        cancellationAction = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: disposition)
        return true
    }

    /**
     Records cooperative cancellation and targets the latest admitted attempt when available.

     - Side effects: Invokes the current attempt's cancellation callback after releasing the lock.
     - Failure modes: Terminal requests and repeated cancellation are harmless no-ops.
     - Concurrency: If no attempt exists yet, the state is retained and delivered by the next claim.
     */
    func cancel() {
        lock.lock()
        guard terminalDisposition == nil, !cancellationRequested else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let claim = generation.map { Claim(requestID: requestID, generation: $0) }
        let cancellationAction = self.cancellationAction
        lock.unlock()
        if let claim, let cancellationAction {
            cancellationAction(claim)
        }
    }
}
