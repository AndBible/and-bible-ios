// EpubLibraryDeletionState.swift -- durable EPUB deletion confirmation sequencing

import Foundation

/** One installed EPUB awaiting a user-confirmed destructive action. */
struct EpubLibraryDeletionCandidate: Equatable {
    /// Stable library identity passed to the throwing storage API.
    let identifier: String

    /// User-visible title displayed by the confirmation dialog.
    let title: String
}

/**
 Owns confirmation and commit sequencing for EPUB deletion from Android's document chooser.

 Requesting deletion only records candidates. `commit` clears that request, invokes the throwing
 storage operation in order, and notifies the reader owner only after each successful commit. This
 keeps reader reconciliation and visible chooser updates behind the same durability boundary as
 Android's `DocumentControl.deleteDocument(...)` action.

 - Side effects: Mutates pending confirmation state and invokes caller-supplied deletion/callback
   closures during `commit`.
 - Failure modes: Stops at the first thrown deletion error and returns it; later candidates are not
   attempted and no success callback is emitted for the failed candidate.
 */
struct EpubLibraryDeletionState {
    /// Candidates currently awaiting explicit destructive confirmation.
    private(set) var pending: [EpubLibraryDeletionCandidate] = []

    /// Whether the chooser should present its destructive confirmation dialog.
    var isAwaitingConfirmation: Bool { !pending.isEmpty }

    /**
     Records candidates for confirmation without touching the file system.

     - Parameter candidates: Installed EPUB identities selected by contextual action mode.
     - Side effects: Replaces any prior pending request.
     - Failure modes: An empty input simply clears pending confirmation.
     */
    mutating func request(_ candidates: [EpubLibraryDeletionCandidate]) {
        pending = candidates
    }

    /** Clears a pending request without deleting or notifying. */
    mutating func cancel() {
        pending = []
    }

    /**
     Commits confirmed deletions in selection order.

     - Parameters:
       - delete: Throwing durable-storage operation for one stable EPUB identifier.
       - onDeleted: Callback emitted only after `delete` returns successfully.
     - Returns: The first deletion error, or `nil` when every requested EPUB committed.
     - Side effects: Clears pending state before I/O, then invokes the supplied closures in order.
     - Failure modes: Stops on the first thrown error; already committed deletions remain committed.
     */
    mutating func commit(
        delete: (String) throws -> Void,
        onDeleted: (String) -> Void
    ) -> Error? {
        let requested = pending
        pending = []
        for candidate in requested {
            do {
                try delete(candidate.identifier)
                onDeleted(candidate.identifier)
            } catch {
                return error
            }
        }
        return nil
    }
}
