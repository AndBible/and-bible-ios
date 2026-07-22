// LatestSearchRequestGate.swift -- Stale asynchronous Search publication guard

import Foundation

/**
 Tracks the one asynchronous operation currently allowed to publish into a Search state lane.

 Every replacement or cancellation creates a new opaque token. A completion may mutate visible
 state only while its captured token is current, preventing an older search or index task from
 overwriting a newer query, option set, failure, or dismissal state.
 */
struct LatestSearchRequestGate: Equatable {
    /// Opaque token representing the latest request or invalidation.
    private var currentToken = UUID()

    /**
     Begins a new request and invalidates every prior token.

     - Returns: Token the new operation must present before publishing.
     - Side effects: Replaces the current token.
     - Failure modes: UUID generation cannot report failure.
     */
    mutating func begin() -> UUID {
        currentToken = UUID()
        return currentToken
    }

    /**
     Invalidates the current operation without beginning another one.

     - Side effects: Replaces the current token so pending completions are rejected.
     - Failure modes: UUID generation cannot report failure.
     */
    mutating func invalidate() {
        currentToken = UUID()
    }

    /**
     Tests whether one captured request may still publish.

     - Parameter token: Token captured when the operation began.
     - Returns: `true` only for the latest non-invalidated operation.
     - Side effects: None.
     - Failure modes: None.
     */
    func accepts(_ token: UUID) -> Bool {
        token == currentToken
    }
}
