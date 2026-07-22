// ModuleStoreMutationCoordinator.swift - Process-wide SWORD module-store transaction boundary

import Foundation

/**
 Identifies the live-tree writer that owns one module-store transaction.

 The value is diagnostic and test-facing; serialization is always keyed by the canonical SWORD
 root rather than by operation kind or `ModuleRepository` instance.
 */
public enum ModuleStoreMutationKind: String, Sendable, Equatable {
    /// Startup recovery of a durably journaled interrupted module-store overlay.
    case recovery

    /// A package-backed remote SWORD install or update.
    case remoteSword

    /// A package-backed remote MyBible install or update.
    case remoteMyBible

    /// A user-selected local SWORD ZIP install or update.
    case localSwordZip

    /// An Android `.abmd.zip` module-backup restore.
    case androidModuleBackup

    /// An app-owned TTF addon config and optional font payload publication.
    case ttfAddon

    /// A SWORD or MyBible uninstall.
    case uninstall
}

/**
 Observable transaction checkpoints used by deterministic concurrency tests and diagnostics.

 Observers run synchronously on the writer's thread. A test may block at `.willMutate` to hold an
 acquired lease without relying on sleeps. Production observers must return promptly.
 */
public enum ModuleStoreMutationStage: String, Sendable, Equatable {
    /// The operation joined the canonical root's FIFO wait queue.
    case waiting

    /// The operation owns the exclusive lease but has not crossed the commit boundary.
    case acquired

    /// Cancellation is no longer observed and the first live-tree mutation is about to run.
    case willMutate

    /// Publication, cache invalidation, and notification completed.
    case committed

    /// Publication failed and rollback was attempted before the error escaped.
    case rolledBack

    /// Cancellation removed the request before the non-cancellable mutation boundary.
    case cancelledBeforeMutation

    /// The exclusive lease has been returned to the next waiter.
    case released
}

/**
 Immutable details for one coordinator checkpoint.

 Values identify a transaction across waiting, commit, rollback, and release events without
 exposing mutable coordinator state.
 */
public struct ModuleStoreMutationEvent: Sendable, Equatable {
    /// Stable identifier for this lease request.
    public let transactionID: UUID

    /// Writer category supplied by the mutation entry point.
    public let kind: ModuleStoreMutationKind

    /// Current coordinator checkpoint.
    public let stage: ModuleStoreMutationStage

    /// Canonical SWORD root used as the process-wide serialization key.
    public let canonicalRootURL: URL
}

/**
 Owns the lifetime of a module-store transaction observer.

 Calling `cancel()` or releasing the token removes the observer. Cancellation is idempotent and
 thread-safe; it does not affect any module transaction.
 */
public final class ModuleStoreMutationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    /// Creates a token around one observer-removal callback.
    fileprivate init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    /**
     Stops delivery of future transaction events.

     Side effects: Removes one callback from a canonical-root coordinator. In-flight callback
     invocation may finish before cancellation returns.
     */
    public func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit {
        cancel()
    }
}

/**
 Serializes every live module-tree mutation for one canonical SWORD root.

 Coordinators are process-wide singletons keyed by symlink-resolved, standardized root path.
 Network, archive parsing, and extraction remain concurrent; writers enter this coordinator only
 before revalidation and the first live-tree mutation. Cancellation is checked while waiting and
 immediately after acquisition. Once `.willMutate` is emitted, the body is deliberately
 non-cancellable and must return the actual commit or rollback result.
 */
public final class ModuleStoreMutationCoordinator: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: ModuleStoreMutationCoordinator] = [:]

    /// Canonical root represented by this coordinator.
    public let canonicalRootURL: URL

    private let condition = NSCondition()
    private var activeTransactionID: UUID?
    private var waiters: [UUID] = []
    private var observers: [UUID: @Sendable (ModuleStoreMutationEvent) -> Void] = [:]

    /// Creates the coordinator retained by the process-wide registry.
    private init(canonicalRootURL: URL) {
        self.canonicalRootURL = canonicalRootURL
    }

    /**
     Returns the process-wide coordinator for a SWORD root.

     - Parameter moduleRootURL: SWORD home containing `mods.d` and `modules`.
     - Returns: The one coordinator associated with the canonical root path.
     - Side effects: Resolves existing symlinks and may retain a new coordinator for process life.
     - Important: Roots that differ textually but resolve to the same directory share a lease.
     */
    public static func shared(forModuleRoot moduleRootURL: URL) -> ModuleStoreMutationCoordinator {
        let canonicalURL = canonicalRoot(moduleRootURL)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[canonicalURL.path] {
            return existing
        }
        let coordinator = ModuleStoreMutationCoordinator(canonicalRootURL: canonicalURL)
        registry[canonicalURL.path] = coordinator
        return coordinator
    }

    /**
     Observes deterministic transaction checkpoints for one canonical SWORD root.

     - Parameters:
       - moduleRootURL: Root whose coordinator should be observed.
       - observer: Synchronous callback invoked for subsequent events.
     - Returns: A token that removes the callback when cancelled or released.
     - Side effects: Mutates process-local diagnostic observer state.
     - Important: Intended for deterministic barriers and lightweight diagnostics; callbacks execute
       while a transaction may hold its exclusive lease.
     */
    public static func observeTransactions(
        forModuleRoot moduleRootURL: URL,
        observer: @escaping @Sendable (ModuleStoreMutationEvent) -> Void
    ) -> ModuleStoreMutationObservation {
        let coordinator = shared(forModuleRoot: moduleRootURL)
        let observerID = UUID()
        coordinator.condition.lock()
        coordinator.observers[observerID] = observer
        coordinator.condition.unlock()
        return ModuleStoreMutationObservation { [weak coordinator] in
            coordinator?.condition.lock()
            coordinator?.observers[observerID] = nil
            coordinator?.condition.unlock()
        }
    }

    /**
     Runs cancellable preparation and a non-cancellable commit under one exclusive lease.

     - Parameters:
       - kind: Writer category reported to observers.
       - prepare: Current-state, conflict, ownership, and containment revalidation with no mutation.
       - commit: Live-tree publication or removal, rollback, cache invalidation, and notification.
     - Returns: The commit closure's return value.
     - Side effects: Blocks this thread in a FIFO queue until the canonical root is available.
     - Throws: `CancellationError` if cancellation is observed before `.willMutate`; otherwise
       rethrows the actual preparation, commit, or rollback error.
     - Important: `prepare` must not mutate the live tree. `commit` is deliberately non-cancellable
       and must not call cancellation checks.
     */
    public func withExclusiveTransaction<Prepared, Result>(
        kind: ModuleStoreMutationKind,
        prepare: () throws -> Prepared,
        commit: (Prepared) throws -> Result
    ) throws -> Result {
        let transactionID = UUID()
        emit(transactionID: transactionID, kind: kind, stage: .waiting)
        do {
            try acquire(transactionID: transactionID)
        } catch {
            emit(transactionID: transactionID, kind: kind, stage: .cancelledBeforeMutation)
            throw error
        }
        emit(transactionID: transactionID, kind: kind, stage: .acquired)

        let prepared: Prepared
        do {
            try Task.checkCancellation()
            prepared = try prepare()
            try Task.checkCancellation()
        } catch {
            if error is CancellationError {
                emit(transactionID: transactionID, kind: kind, stage: .cancelledBeforeMutation)
            }
            release(transactionID: transactionID, kind: kind)
            throw error
        }

        emit(transactionID: transactionID, kind: kind, stage: .willMutate)
        do {
            let result = try commit(prepared)
            emit(transactionID: transactionID, kind: kind, stage: .committed)
            release(transactionID: transactionID, kind: kind)
            return result
        } catch {
            emit(transactionID: transactionID, kind: kind, stage: .rolledBack)
            release(transactionID: transactionID, kind: kind)
            throw error
        }
    }

    /** Waits in FIFO order while polling task cancellation without entering the mutation phase. */
    private func acquire(transactionID: UUID) throws {
        condition.lock()
        waiters.append(transactionID)
        while activeTransactionID != nil || waiters.first != transactionID {
            if Task.isCancelled {
                waiters.removeAll { $0 == transactionID }
                condition.broadcast()
                condition.unlock()
                throw CancellationError()
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        if Task.isCancelled {
            waiters.removeFirst()
            condition.broadcast()
            condition.unlock()
            throw CancellationError()
        }
        waiters.removeFirst()
        activeTransactionID = transactionID
        condition.unlock()
    }

    /** Releases the active transaction and wakes every waiter so the FIFO head can continue. */
    private func release(transactionID: UUID, kind: ModuleStoreMutationKind) {
        condition.lock()
        if activeTransactionID == transactionID {
            activeTransactionID = nil
        }
        condition.broadcast()
        condition.unlock()
        emit(transactionID: transactionID, kind: kind, stage: .released)
    }

    /** Delivers one immutable event to a stable observer snapshot without holding coordinator state. */
    private func emit(
        transactionID: UUID,
        kind: ModuleStoreMutationKind,
        stage: ModuleStoreMutationStage
    ) {
        condition.lock()
        let callbacks = Array(observers.values)
        condition.unlock()
        let event = ModuleStoreMutationEvent(
            transactionID: transactionID,
            kind: kind,
            stage: stage,
            canonicalRootURL: canonicalRootURL
        )
        callbacks.forEach { $0(event) }
    }

    /** Resolves existing symlinks and normalizes one root for registry identity. */
    private static func canonicalRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
}
