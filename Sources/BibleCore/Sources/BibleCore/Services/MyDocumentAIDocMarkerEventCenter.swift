// MyDocumentAIDocMarkerEventCenter.swift -- App-owned AI marker change propagation

import Foundation

/**
 Describes committed AI document marker changes that every open reader pane must apply.

 Android broadcasts the same marker upserts and deleted page identifiers to each `BibleView`.
 This value keeps that contract typed across iOS persistence and reader layers without exposing
 untyped notification dictionaries.

 - Side effects: None; this is an immutable event value.
 - Failure modes: Empty arrays represent a no-op and are ignored by the event center.
 */
public struct MyDocumentAIDocMarkersChangedEvent: Equatable, Sendable {
    /// Complete marker values to add or replace by generated page identifier.
    public let markers: [MyDocumentAIDocMarker]

    /// Generated page identifiers whose markers must be removed.
    public let deletedPageIDs: [UUID]

    /**
     Creates one committed marker change event.

     - Parameters:
       - markers: Marker values to add or replace.
       - deletedPageIDs: Generated page identifiers to remove.
     - Side effects: None.
     - Failure modes: None; empty collections are permitted and treated as a no-op when posted.
     */
    public init(
        markers: [MyDocumentAIDocMarker] = [],
        deletedPageIDs: [UUID] = []
    ) {
        self.markers = markers
        self.deletedPageIDs = deletedPageIDs
    }
}

/**
 Owns one cancellable subscription to AI document marker changes.

 The token removes its observer exactly once when cancelled or deinitialized. Cancellation is
 lock-protected so pane teardown can race safely with event delivery.

 - Side effects: Cancelling unregisters one callback from its event center.
 - Failure modes: Repeated cancellation is a no-op.
 */
public final class MyDocumentAIDocMarkerEventObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    /**
     Creates an observation token around one unregister operation.

     - Parameter cancellation: Idempotent work supplied by the owning event center.
     - Side effects: Stores the closure only; registration has already occurred.
     - Failure modes: None.
     */
    fileprivate init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    /**
     Removes the associated event observer exactly once.

     - Side effects: Invokes the stored unregister closure on the calling thread.
     - Failure modes: None; subsequent calls return without invoking the closure again.
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
 Publishes typed AI document marker changes to every live reader-pane subscriber.

 Persistence owners post only after a successful save. Delivery is synchronous on the posting
 thread, matching the caller's SwiftData/UI confinement, and callbacks run outside the internal
 lock so observers may cancel themselves safely.

 - Side effects: Retains registered callbacks and invokes each callback for every non-empty event.
 - Failure modes: Observer order is unspecified; one observer cannot suppress delivery to another.
 */
public final class MyDocumentAIDocMarkerEventCenter: @unchecked Sendable {
    /// Process-wide event center used by production persistence stores and reader controllers.
    public static let shared = MyDocumentAIDocMarkerEventCenter()

    private let lock = NSLock()
    private var observers: [UUID: (MyDocumentAIDocMarkersChangedEvent) -> Void] = [:]

    /**
     Creates an isolated event center.

     Tests use isolated instances to prove multi-pane delivery without process-global state.

     - Side effects: None.
     - Failure modes: None.
     */
    public init() {}

    /**
     Registers one typed marker-change callback.

     - Parameter observer: Callback invoked synchronously for each non-empty event.
     - Returns: Token that unregisters the callback when cancelled or deinitialized.
     - Side effects: Retains the callback until its token is cancelled.
     - Failure modes: None.
     */
    @discardableResult
    public func observe(
        _ observer: @escaping (MyDocumentAIDocMarkersChangedEvent) -> Void
    ) -> MyDocumentAIDocMarkerEventObservation {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        return MyDocumentAIDocMarkerEventObservation { [weak self] in
            self?.removeObserver(id: id)
        }
    }

    /**
     Delivers one committed marker change to every current observer.

     - Parameter event: Typed upserts and deletions from a successful persistence operation.
     - Side effects: Invokes a snapshot of current callbacks synchronously on the calling thread.
     - Failure modes: Empty events are ignored; callback failures cannot be represented in Swift.
     */
    public func post(_ event: MyDocumentAIDocMarkersChangedEvent) {
        guard !event.markers.isEmpty || !event.deletedPageIDs.isEmpty else { return }
        lock.lock()
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0(event) }
    }

    /**
     Removes one observer by its internal registration identifier.

     - Parameter id: Identifier captured by the observation token.
     - Side effects: Releases the callback when it is still registered.
     - Failure modes: Unknown identifiers are ignored.
     */
    private func removeObserver(id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}
