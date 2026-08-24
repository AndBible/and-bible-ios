// SearchIndexRuntimeState.swift — Cross-queue Search indexing authorization and mutation state

import Foundation
import SwordKit

/**
 Thread-safe cancellation state shared between a Swift task and the serial SQLite mutation queue.

 - Side effects: `cancel()` permanently flips one lock-protected bit for this build operation.
 - Failure modes: `checkCancellation()` throws only after cancellation; lock access is synchronous.
 */
final class SearchIndexCancellationProbe: @unchecked Sendable {
    /// Protects the cancellation bit across task and GCD execution contexts.
    private let lock = NSLock()

    /// Whether the owning indexing task has requested cancellation.
    private var cancelled = false

    /**
     Records cancellation without blocking on the index mutation queue.

     - Side effects: Sets the lock-protected cancellation bit permanently for this probe.
     - Failure modes: None.
     */
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /**
     Rejects the next source read or generated-index write after cancellation.

     - Side effects: Reads the lock-protected cancellation bit.
     - Throws: `CancellationError` when `cancel()` has been called; otherwise returns normally.
     */
    func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { throw CancellationError() }
    }
}

/**
 Explicitly transfers one backend source into the service's serialized indexing queue.

 Source adapters include mutable SWORD cursors and operation-owned SQLite readers that cannot claim
 general `Sendable` conformance. `createIndex` captures this box once and `buildIndex` is the only code
 that accesses its value after the handoff, entirely on `indexMutationQueue`.
 */
final class SearchIndexSourceTransfer: @unchecked Sendable {
    /// Source value accessed only by the receiving serialized mutation closure.
    let value: any BibleSearchIndexSource

    /**
     Wraps one source for a single serialized-queue ownership handoff.

     - Parameter value: Backend source retained until the receiving mutation closure executes.
     - Side effects: Retains `value`; no backend read or mutation occurs.
     - Failure modes: None.
     */
    init(_ value: any BibleSearchIndexSource) {
        self.value = value
    }
}

/**
 Opaque proof that one installed Search source was captured in a specific module-store generation.

 Search queues may retain source objects while earlier modules build. The token binds that retained
 source identity to the service instance, durable store generation, and monotonic in-memory
 invalidation epoch that were current at discovery. Callers can store and return the value only to
 the issuing `SearchIndexService`; they cannot construct or inspect its authorization fields.
 */
public struct SearchIndexSourceAuthorization: Sendable {
    /// Service instance that issued the authorization and is allowed to consume it.
    let serviceIdentifier: UUID

    /// Exact source identity observed when the queue captured the source object.
    let sourceIdentity: SearchIndexSourceIdentity

    /// Durable module-store generation observed with the source capture.
    let storeGeneration: Int64

    /// In-memory invalidation epoch that detects a replacement even across an old SQLite snapshot.
    let invalidationEpoch: UInt64
}

/**
 Tracks Android-compatible per-module Search mutation status across asynchronous queue handoffs.

 Android exposes a book as `SCHEDULED`/`CREATING`, rather than `DONE`, from the moment indexing is
 requested until its terminal outcome. Counts preserve that contract when duplicate requests for the
 same initials are queued: finishing the first request cannot make the module readable while another
 mutation remains scheduled.
 */
final class SearchIndexModuleMutationState: @unchecked Sendable {
    /// Protects reference counts shared by callers, the mutation queue, Search tasks, and agent work.
    private let lock = NSLock()

    /// Number of scheduled or active mutations for each exact module initials value.
    private var countsByModule: [SwordJavaExactStringIdentity: Int] = [:]

    /**
     Marks one module unavailable before its mutation is handed to the serial SQLite queue.

     - Parameter moduleName: Exact generated-index owner entering scheduled/creating state.
     - Side effects: Increments one lock-protected reference count.
     - Failure modes: None; duplicate requests intentionally retain independent counts.
     - Important: Every call must be paired with `finishMutation(for:)` on every terminal path.
     */
    func beginMutation(for moduleName: String) {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        countsByModule[identity, default: 0] += 1
        lock.unlock()
    }

    /**
     Releases one scheduled/active mutation without clearing a later duplicate request.

     - Parameter moduleName: Exact generated-index owner reaching success, failure, or cancellation.
     - Side effects: Decrements or removes one lock-protected reference count.
     - Failure modes: An unmatched release is ignored defensively and cannot create a negative count.
     */
    func finishMutation(for moduleName: String) {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        if let count = countsByModule[identity] {
            if count > 1 {
                countsByModule[identity] = count - 1
            } else {
                countsByModule.removeValue(forKey: identity)
            }
        }
        lock.unlock()
    }

    /**
     Returns whether Android would currently expose one module as scheduled or creating.

     - Parameter moduleName: Exact generated-index owner queried by Search or agent code.
     - Returns: `true` while at least one mutation request remains pending or active.
     - Side effects: Acquires the state lock briefly; no database or observable state is changed.
     - Failure modes: None.
     */
    func isMutating(_ moduleName: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        let mutating = countsByModule[identity] != nil
        lock.unlock()
        return mutating
    }
}

/**
 Owns Search's monotonic module-store invalidation epoch and fail-closed overlap state.

 The epoch advances before durable SQLite invalidation enters the mutation queue, so a logical read
 pinned to an older WAL snapshot can still detect replacement. A failed durable update permanently
 blocks readiness for the service lifetime rather than serving stale generated rows.
 */
final class SearchIndexInvalidationEpochState: @unchecked Sendable {
    /// Protects epoch, pending-count, and permanent-failure state across readers and notifications.
    private let lock = NSLock()

    /// Number of durable generation updates not yet completed.
    private var pendingCount = 0

    /// Whether any durable invalidation failed and permanently closed this service to reads.
    private var failed = false

    /// Monotonic logical epoch advanced synchronously at notification admission.
    private var epoch: UInt64 = 0

    /**
     Starts one store invalidation and permanently advances the logical epoch.

     - Side effects: Increments the lock-protected epoch and pending count.
     - Failure modes: None; overflow wraps intentionally like the prior service-owned counter.
     */
    func begin() {
        lock.lock()
        epoch &+= 1
        pendingCount += 1
        lock.unlock()
    }

    /**
     Completes one overlapping durable invalidation.

     - Parameter succeeded: Whether this notification's generation update committed durably.
     - Side effects: Decrements pending state and permanently records a failure when needed.
     - Failure modes: An unmatched completion cannot make the pending count negative.
     */
    func complete(succeeded: Bool) {
        lock.lock()
        if pendingCount > 0 { pendingCount -= 1 }
        if !succeeded { failed = true }
        lock.unlock()
    }

    /**
     Returns whether readiness and query admission must fail closed.

     - Returns: `true` while any durable invalidation is pending or after one has failed.
     - Side effects: Acquires the state lock briefly.
     - Failure modes: None.
     */
    func isBlocked() -> Bool {
        lock.lock()
        let blocked = failed || pendingCount > 0
        lock.unlock()
        return blocked
    }

    /**
     Captures the epoch authorizing one newly admitted logical read.

     - Returns: Current epoch after all durable invalidations settle, otherwise nil.
     - Side effects: Acquires the state lock briefly.
     - Failure modes: Pending or permanent failure returns nil.
     */
    func captureReadEpoch() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !failed, pendingCount == 0 else { return nil }
        return epoch
    }

    /**
     Validates that no module-store mutation overlapped one admitted logical read.

     - Parameter expectedEpoch: Epoch captured before the read-only SQLite snapshot opened.
     - Returns: `true` only when the epoch is unchanged and no invalidation is pending/failed.
     - Side effects: Acquires the state lock briefly.
     - Failure modes: Any intervening, pending, or failed store mutation returns false.
     */
    func isCurrent(_ expectedEpoch: UInt64) -> Bool {
        lock.lock()
        let current = !failed && pendingCount == 0 && epoch == expectedEpoch
        lock.unlock()
        return current
    }
}
