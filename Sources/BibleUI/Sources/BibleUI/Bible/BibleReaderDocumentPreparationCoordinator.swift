// BibleReaderDocumentPreparationCoordinator.swift -- Immutable reader work ownership

import Foundation
import SwordKit
import os.signpost

/** Exact Java-compatible UTF-16 identity for Android-owned document and source keys. */
struct BibleReaderPreparationExactText: Hashable, Sendable, ExpressibleByStringLiteral {
    /// Original spelling retained for bounded diagnostics and downstream source lookup.
    let rawValue: String
    private let utf16CodeUnits: [UInt16]

    init(_ rawValue: String) {
        self.rawValue = rawValue
        utf16CodeUnits = Array(rawValue.utf16)
    }

    init(stringLiteral value: String) {
        self.init(value)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.utf16CodeUnits == rhs.utf16CodeUnits
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(utf16CodeUnits)
    }
}

/** Exact backing dependencies retained by prepared source and annotation values. */
enum BibleReaderPreparationSourceDependency: Hashable, Sendable {
    /// One manager/root generation and every canonical SWORD module read by the preparation.
    case sword(
        manager: ObjectIdentifier,
        authorization: SwordContentAuthorizationSnapshot
    )
    /// One currently registered immutable SQLite module facade.
    case sqlite(
        module: ObjectIdentifier,
        initials: BibleReaderPreparationExactText
    )
    /// One leased immutable EPUB generation.
    case epub(
        identifier: BibleReaderPreparationExactText,
        generation: BibleReaderPreparationExactText
    )
    /// One persisted source row and exact copied revision.
    case persisted(
        kind: BibleReaderPreparationExactText,
        identity: BibleReaderPreparationExactText,
        revision: BibleReaderPreparationExactText
    )
    /// One exact persisted My Documents page copied without timestamps or live model references.
    case myDocument(BibleReaderPreparedMyDocumentSource)
    /// Values that require no mutable external source after owner capture.
    case independent
}

/** Exact owner-side identity used for request coalescing without hashing serialized documents. */
enum BibleReaderPreparationAnnotationIdentity: Hashable, Sendable, ExpressibleByStringLiteral {
    /// Typed exhaustive Bible-document owner identity.
    case bible(BibleReaderBibleDocumentOwnerIdentity)
    /// Exact structural inputs for one My Documents page preparation.
    case myDocumentRequest(BibleReaderMyDocumentPreparationRequestIdentity)
    /// Exact structural inputs for one Memorize document preparation.
    case memorizeRequest(BibleReaderMemorizePreparationRequestIdentity)
    /// Exact structural inputs for one Multi or Compare source operation.
    case compositeRequest(BibleReaderCompositePreparationRequestIdentity)
    /// Exact structural inputs and source-selection settings for a definition operation.
    case definitionRequest(BibleReaderDefinitionPreparationRequestIdentity)
    /// Exact text retained for source families whose typed snapshots are introduced independently.
    case exactText(BibleReaderPreparationExactText)

    init(_ exactText: BibleReaderPreparationExactText) {
        self = .exactText(exactText)
    }

    init(stringLiteral value: String) {
        self = .exactText(BibleReaderPreparationExactText(value))
    }
}

/** Stable source generation retained by one reader preparation request. */
enum BibleReaderPreparationSourceIdentity: Hashable, Sendable {
    /// One exact module owned by one manager generation.
    case sword(
        manager: ObjectIdentifier,
        module: ObjectIdentifier,
        initials: BibleReaderPreparationExactText,
        generation: SwordContentAuthorizationGeneration,
        modules: [BibleReaderPreparationExactText]
    )
    /// One manager generation whose requested module is resolved inside the worker lease.
    case swordManager(
        manager: ObjectIdentifier,
        generation: SwordContentAuthorizationGeneration,
        requestedModules: [BibleReaderPreparationExactText]
    )
    /// Installed-source registry used to reject local-document collisions before owner capture.
    case installedRegistry(
        swordManager: ObjectIdentifier?,
        swordGeneration: SwordContentAuthorizationGeneration?,
        sqliteModules: [BibleReaderPreparationSQLiteIdentity]
    )
    /// One immutable SQLite module facade whose reads own independent connections.
    case sqlite(module: ObjectIdentifier, initials: BibleReaderPreparationExactText)
    /// One leased immutable EPUB package/index generation.
    case epub(
        identifier: BibleReaderPreparationExactText,
        generation: BibleReaderPreparationExactText
    )
    /// One persisted local value identified by stable row identity and update token.
    case persisted(
        kind: BibleReaderPreparationExactText,
        identity: BibleReaderPreparationExactText,
        revision: BibleReaderPreparationExactText
    )
    /// One composite whose independently authorized sources are encoded in deterministic order.
    case composite([BibleReaderPreparationExactText])
    /// Exact heterogeneous dependencies retained without string flattening.
    case dependencies([BibleReaderPreparationSourceDependency])
    /// A bounded source-independent payload such as an explicit error document.
    case independent
}

/** Exact immutable SQLite facade identity retained in an installed-source request key. */
struct BibleReaderPreparationSQLiteIdentity: Hashable, Sendable {
    let module: ObjectIdentifier
    let initials: BibleReaderPreparationExactText
}

/**
 Identity used to coalesce equivalent work and reject results from another pane or source generation.

 The key intentionally excludes serialized document bodies. Correlation and scheduling therefore
 never stringify a large payload merely to log or compare requests.
 */
struct BibleReaderDocumentPreparationKey: Hashable, Sendable {
    /// Reader document family, such as `bible`, `study-pad`, or `multi`.
    let family: BibleReaderPreparationExactText
    /// Exact destination pane identity, if a persisted Window owns the reader.
    let paneID: UUID?
    /// Exact workspace identity owning the destination pane.
    let workspaceID: UUID?
    /// Immutable backing generation retained through source capture.
    let source: BibleReaderPreparationSourceIdentity
    /// Exact source key/range/config identity without serialized content bytes.
    let contentIdentity: BibleReaderPreparationExactText
    /// Exact typed owner snapshot used to coalesce only equivalent emitted values.
    let annotationIdentity: BibleReaderPreparationAnnotationIdentity
}

/** Independent request lanes owned by one reader controller. */
enum BibleReaderDocumentPreparationScope: Hashable, Sendable {
    /// Work that replaces the complete visible document generation.
    case replacement
    /// One pending Vue prepend callback.
    case prepend
    /// One pending Vue append callback.
    case append
    /// Outbound prepared payload routed to another pane without replacing this pane's document.
    case transient
}

/** Observable preparation phases used by tests and passive signpost instrumentation. */
enum BibleReaderDocumentPreparationPhase: String, Sendable {
    case sourceCapture = "source-capture"
    case projection
    case ownerCapture = "owner-capture"
    case sourceEnrichment = "source-enrichment"
    case encoding
    case publication
}

/** Whether a submitted request started work or joined an equivalent in-flight operation. */
enum BibleReaderDocumentPreparationSubmission: Equatable, Sendable {
    case started(requestID: UInt64)
    case coalesced(requestID: UInt64)
}

/** Exact terminal cause delivered by the preparation scheduler to its main-queue owner. */
enum BibleReaderDocumentPreparationOutcome<Result: Sendable>: Sendable {
    /// Every preparation phase succeeded and produced one immutable encoded value.
    case prepared(Result)
    /// Capture, projection, owner capture, enrichment, or encoding could not produce a value.
    case phaseFailed
    /// Work completed, but the latest equivalent caller no longer authorizes publication.
    case authorizationRejected
    /// A newer operation or explicit lifecycle event cancelled this operation.
    case cancelled
}

/** Thread-safe cancellation query retained by one preparation source capture. */
struct BibleReaderPreparationCancellation: Sendable {
    private let query: @Sendable () -> Bool

    /** Whether a newer operation or an explicit lifecycle event cancelled this capture. */
    var isCancelled: Bool { query() }

    /** Creates an immutable query without exposing mutable coordinator state. */
    fileprivate init(query: @escaping @Sendable () -> Bool) {
        self.query = query
    }
}

/** Type-erased cancellation surface for operations retained in independent request lanes. */
private protocol BibleReaderAnyPreparationOperation: AnyObject {
    var requestID: UInt64 { get }
    var key: BibleReaderDocumentPreparationKey { get }
    func cancel()
}

/**
 One retained preparation operation and every equivalent caller awaiting its result.

 The worker closure retains source objects until native capture returns. Cancellation settles all
 callbacks but deliberately does not release those leases while native code can still be running.
 */
private final class BibleReaderPreparationOperation<Result: Sendable>: BibleReaderAnyPreparationOperation,
    @unchecked Sendable
{
    let requestID: UInt64
    let key: BibleReaderDocumentPreparationKey
    private var completions: [(BibleReaderDocumentPreparationOutcome<Result>) -> Void]
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var acceptingCompletions = true
    private var authorization: () -> Bool

    var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    init(
        requestID: UInt64,
        key: BibleReaderDocumentPreparationKey,
        authorization: @escaping () -> Bool = { true },
        completion: @escaping (BibleReaderDocumentPreparationOutcome<Result>) -> Void
    ) {
        self.requestID = requestID
        self.key = key
        self.authorization = authorization
        completions = [completion]
    }

    func append(
        completion: @escaping (BibleReaderDocumentPreparationOutcome<Result>) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard acceptingCompletions, !isCancelled else {
            completion(.cancelled)
            return
        }
        completions.append(completion)
    }

    var canAcceptCompletion: Bool {
        precondition(Thread.isMainThread)
        return acceptingCompletions && !isCancelled
    }

    /** Replaces caller-intent authorization when equivalent newer work joins this operation. */
    func updateAuthorization(_ authorization: @escaping () -> Bool) {
        precondition(Thread.isMainThread)
        self.authorization = authorization
    }

    /** Evaluates the most recent equivalent caller's main-owner authorization. */
    func isAuthorized() -> Bool {
        precondition(Thread.isMainThread)
        return authorization()
    }

    func finish(_ outcome: BibleReaderDocumentPreparationOutcome<Result>) {
        precondition(Thread.isMainThread)
        acceptingCompletions = false
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks {
            callback(isCancelled ? .cancelled : outcome)
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        cancellationLock.lock()
        let wasCancelled = cancelled
        cancelled = true
        cancellationLock.unlock()
        guard !wasCancelled else { return }
        acceptingCompletions = false
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(.cancelled) }
    }
}

/**
 Owns asynchronous reader preparation, coalescing, cancellation, and passive phase diagnostics.

 Callers capture SwiftData values before submission on their owning context. This coordinator then
 runs source capture, pure projection, and encoding on its worker queue. Publication returns to the
 main owner and succeeds only after the caller's authorization closure validates pane, workspace,
 source generation, authorization, and current request state.
 */
final class BibleReaderDocumentPreparationCoordinator: @unchecked Sendable {
    typealias PhaseObserver = @Sendable (
        _ phase: BibleReaderDocumentPreparationPhase,
        _ requestID: UInt64,
        _ key: BibleReaderDocumentPreparationKey
    ) -> Void

    private static let signpostLog = OSLog(
        subsystem: "org.andbible",
        category: "BibleReaderDocumentPreparation"
    )

    private let workerQueue: DispatchQueue
    private let phaseObserver: PhaseObserver?
    private var nextRequestID: UInt64 = 0
    private var activeOperations: [
        BibleReaderDocumentPreparationScope: BibleReaderAnyPreparationOperation
    ] = [:]

    /** Creates a production coordinator with an injectable deterministic worker for tests. */
    init(
        workerQueue: DispatchQueue = DispatchQueue(
            label: "org.andbible.reader-document-preparation",
            qos: .userInitiated,
            attributes: .concurrent
        ),
        phaseObserver: PhaseObserver? = nil
    ) {
        self.workerQueue = workerQueue
        self.phaseObserver = phaseObserver
    }

    /**
     Submits immutable preparation while preserving its exact terminal cause for publication policy.

     This is the production ownership boundary. Every caller receives an explicit terminal cause so
     its publication owner can distinguish source failure, invalidation, and lifecycle cancellation.
     */
    @discardableResult
    func submitReportingOutcome<Captured: Sendable, Projected: Sendable, Encoded: Sendable>(
        scope: BibleReaderDocumentPreparationScope,
        key: BibleReaderDocumentPreparationKey,
        captureSource: @escaping @Sendable () -> Captured?,
        project: @escaping @Sendable (Captured) -> Projected?,
        encode: @escaping @Sendable (Projected) -> Encoded?,
        isAuthorized: @escaping () -> Bool,
        completion: @escaping (BibleReaderDocumentPreparationOutcome<Encoded>) -> Void
    ) -> BibleReaderDocumentPreparationSubmission {
        dispatchPrecondition(condition: .onQueue(.main))

        if let equivalent = activeOperations[scope] as? BibleReaderPreparationOperation<Encoded>,
           equivalent.key == key,
           equivalent.canAcceptCompletion {
            equivalent.updateAuthorization(isAuthorized)
            equivalent.append { outcome in
                completion(Self.authorizedOutcome(outcome, isAuthorized: isAuthorized))
            }
            return .coalesced(requestID: equivalent.requestID)
        }

        nextRequestID &+= 1
        let operation = BibleReaderPreparationOperation<Encoded>(
            requestID: nextRequestID,
            key: key,
            authorization: isAuthorized,
            completion: { outcome in
                completion(Self.authorizedOutcome(outcome, isAuthorized: isAuthorized))
            }
        )
        let displaced = replaceActiveOperations(with: operation, in: scope)
        displaced.forEach { $0.cancel() }

        // A cancellation callback can synchronously submit newer work. Do not queue this operation
        // if that reentrant request already superseded it and settled its completion.
        guard activeOperations[scope] === operation, !operation.isCancelled else {
            return .started(requestID: operation.requestID)
        }

        workerQueue.async { [self, operation] in
            guard !operation.isCancelled else { return }
            let captured = self.measure(.sourceCapture, operation: operation) {
                captureSource()
            }
            guard !operation.isCancelled else { return }
            guard let captured else {
                self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                return
            }
            let projected = self.measure(.projection, operation: operation) {
                project(captured)
            }
            guard !operation.isCancelled else { return }
            guard let projected else {
                self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                return
            }
            let encoded = self.measure(.encoding, operation: operation) {
                encode(projected)
            }
            guard !operation.isCancelled else { return }
            guard let encoded else {
                self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                return
            }
            self.enqueueCompletion(.prepared(encoded), scope: scope, operation: operation)
        }
        return .started(requestID: operation.requestID)
    }

    /**
     Owner-capture variant that retains phase, authorization, and cancellation terminal causes.

     The immutable query observes the same retained operation cancelled by replacement and
     `cancelAll`. It cannot interrupt a native call already in progress; callers check it before
     beginning another read and after each completed read. Captures without bounded work explicitly
     ignore the query. Existing post-phase cancellation remains authoritative, so an incomplete local
     capture can never reach projection or publication.

     - Parameters: The immutable request, phase closures, authorization, and completion owners;
       `captureSource` receives the operation-owned cancellation query.
     - Returns: Whether this request started work or coalesced with an equivalent operation.
     - Side effects: Replaces conflicting lanes, settles displaced callbacks on main, and performs
       accepted preparation phases on the coordinator's existing worker queue.
     - Failure modes: Reports the existing typed terminal outcome; cancellation never converts to a
       source-phase failure or permits partial publication.
     */
    @discardableResult
    func submitWithOwnerCaptureReportingOutcome<
        Captured: Sendable,
        Projected: Sendable,
        Owner: Sendable,
        Enriched: Sendable,
        Encoded: Sendable
    >(
        scope: BibleReaderDocumentPreparationScope,
        key: BibleReaderDocumentPreparationKey,
        captureSource: @escaping @Sendable (BibleReaderPreparationCancellation) -> Captured?,
        project: @escaping @Sendable (Captured) -> Projected?,
        captureOwner: @escaping (Projected) -> Owner?,
        enrichSource: @escaping @Sendable (Projected, Owner) -> Enriched?,
        encode: @escaping @Sendable (Projected, Owner, Enriched) -> Encoded?,
        isAuthorized: @escaping () -> Bool,
        completion: @escaping (BibleReaderDocumentPreparationOutcome<Encoded>) -> Void
    ) -> BibleReaderDocumentPreparationSubmission {
        dispatchPrecondition(condition: .onQueue(.main))

        if let equivalent = activeOperations[scope] as? BibleReaderPreparationOperation<Encoded>,
           equivalent.key == key,
           equivalent.canAcceptCompletion {
            equivalent.updateAuthorization(isAuthorized)
            equivalent.append { outcome in
                completion(Self.authorizedOutcome(outcome, isAuthorized: isAuthorized))
            }
            return .coalesced(requestID: equivalent.requestID)
        }

        nextRequestID &+= 1
        let operation = BibleReaderPreparationOperation<Encoded>(
            requestID: nextRequestID,
            key: key,
            authorization: isAuthorized,
            completion: { outcome in
                completion(Self.authorizedOutcome(outcome, isAuthorized: isAuthorized))
            }
        )
        let displaced = replaceActiveOperations(with: operation, in: scope)
        displaced.forEach { $0.cancel() }
        guard activeOperations[scope] === operation, !operation.isCancelled else {
            return .started(requestID: operation.requestID)
        }

        workerQueue.async { [self, operation] in
            guard !operation.isCancelled else { return }
            let cancellation = BibleReaderPreparationCancellation { [weak operation] in
                operation?.isCancelled ?? true
            }
            let captured = self.measure(.sourceCapture, operation: operation) {
                captureSource(cancellation)
            }
            guard !operation.isCancelled else { return }
            guard let captured else {
                self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                return
            }
            let projected = self.measure(.projection, operation: operation) {
                project(captured)
            }
            guard !operation.isCancelled else { return }
            guard let projected else {
                self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                return
            }

            DispatchQueue.main.async { [self, operation] in
                guard self.activeOperations[scope] === operation,
                      !operation.isCancelled,
                      operation.isAuthorized() else {
                    self.enqueueCompletion(
                        .authorizationRejected,
                        scope: scope,
                        operation: operation
                    )
                    return
                }
                let owner = self.measure(.ownerCapture, operation: operation) {
                    captureOwner(projected)
                }
                guard !operation.isCancelled, let owner else {
                    self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                    return
                }
                self.workerQueue.async { [self, operation] in
                    guard !operation.isCancelled else { return }
                    let enriched = self.measure(.sourceEnrichment, operation: operation) {
                        enrichSource(projected, owner)
                    }
                    guard !operation.isCancelled else { return }
                    guard let enriched else {
                        self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                        return
                    }
                    let encoded = self.measure(.encoding, operation: operation) {
                        encode(projected, owner, enriched)
                    }
                    guard !operation.isCancelled else { return }
                    guard let encoded else {
                        self.enqueueCompletion(.phaseFailed, scope: scope, operation: operation)
                        return
                    }
                    self.enqueueCompletion(.prepared(encoded), scope: scope, operation: operation)
                }
            }
        }
        return .started(requestID: operation.requestID)
    }

    /** Cancels every pending result and settles its registered completion as cancelled. */
    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        let operations = Array(activeOperations.values)
        activeOperations.removeAll()
        operations.forEach { $0.cancel() }
    }

    /** Reserves the new operation before returning displaced work for reentrant-safe settlement. */
    private func replaceActiveOperations(
        with operation: BibleReaderAnyPreparationOperation,
        in scope: BibleReaderDocumentPreparationScope
    ) -> [BibleReaderAnyPreparationOperation] {
        if scope == .replacement {
            let displaced = Array(activeOperations.values)
            activeOperations.removeAll()
            activeOperations[scope] = operation
            return displaced
        }
        let displaced = activeOperations.removeValue(forKey: scope).map { [$0] } ?? []
        activeOperations[scope] = operation
        return displaced
    }

    /** Returns one exact terminal cause to the main owner and releases the lane afterward. */
    private func enqueueCompletion<Result: Sendable>(
        _ outcome: BibleReaderDocumentPreparationOutcome<Result>,
        scope: BibleReaderDocumentPreparationScope,
        operation: BibleReaderPreparationOperation<Result>
    ) {
        DispatchQueue.main.async { [self, operation] in
            guard self.activeOperations[scope] === operation else { return }
            self.measure(.publication, operation: operation) {
                operation.finish(outcome)
            }
            if self.activeOperations[scope] === operation {
                self.activeOperations[scope] = nil
            }
        }
    }

    /** Applies one caller's latest authorization without erasing cancellation provenance. */
    private static func authorizedOutcome<Result: Sendable>(
        _ outcome: BibleReaderDocumentPreparationOutcome<Result>,
        isAuthorized: () -> Bool
    ) -> BibleReaderDocumentPreparationOutcome<Result> {
        if case .cancelled = outcome { return .cancelled }
        return isAuthorized() ? outcome : .authorizationRejected
    }

    /** Emits one bounded signpost interval and optional deterministic test observer event. */
    private func measure<Value>(
        _ phase: BibleReaderDocumentPreparationPhase,
        operation: BibleReaderAnyPreparationOperation,
        body: () -> Value
    ) -> Value {
        phaseObserver?(phase, operation.requestID, operation.key)
        let signpostID = OSSignpostID(log: Self.signpostLog, object: operation)
        let name: StaticString
        switch phase {
        case .sourceCapture: name = "Reader source capture"
        case .projection: name = "Reader projection"
        case .ownerCapture: name = "Reader owner capture"
        case .sourceEnrichment: name = "Reader source enrichment"
        case .encoding: name = "Reader encoding"
        case .publication: name = "Reader publication"
        }
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: name,
            signpostID: signpostID,
            "request=%{public}llu pane=%{public}@ family=%{public}@",
            operation.requestID,
            operation.key.paneID?.uuidString ?? "unowned",
            operation.key.family.rawValue
        )
        defer {
            os_signpost(.end, log: Self.signpostLog, name: name, signpostID: signpostID)
        }
        return body()
    }
}
