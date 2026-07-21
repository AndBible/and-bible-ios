// EpubLibraryDeletionStateTests.swift -- confirmation and success-only EPUB deletion sequencing

import XCTest
@testable import BibleUI

/**
 Verifies the EPUB library never mutates storage before confirmation and never reports failed
 deletions as successful.

 Tests use injected closures only; no app library or global reader state is touched. Ordering is
 synchronous and deterministic.
 */
final class EpubLibraryDeletionStateTests: XCTestCase {
    /**
     Proves a swipe request and cancellation perform no deletion work.

     The candidate becomes pending for confirmation, then cancellation clears it without invoking
     either storage or owner callbacks. A failure would allow an ordinary row gesture to bypass the
     Android confirmation dialog.
     */
    func testDeletionRequestRequiresConfirmationBeforeStorageMutation() {
        var state = EpubLibraryDeletionState()
        let candidate = EpubLibraryDeletionCandidate(identifier: "book-one", title: "Book One")
        var deletedIdentifiers: [String] = []

        state.request([candidate])

        XCTAssertTrue(state.isAwaitingConfirmation)
        XCTAssertEqual(state.pending, [candidate])
        XCTAssertTrue(deletedIdentifiers.isEmpty)

        state.cancel()
        let error = state.commit(
            delete: { deletedIdentifiers.append($0) },
            onDeleted: { deletedIdentifiers.append("notified:\($0)") }
        )

        XCTAssertNil(error)
        XCTAssertFalse(state.isAwaitingConfirmation)
        XCTAssertTrue(deletedIdentifiers.isEmpty)
    }

    /**
     Proves owner reconciliation occurs only after each durable delete succeeds.

     Three candidates are confirmed and the second storage call throws. The first identifier must be
     reported as committed, the failed and later identifiers must not be reported, and no pending
     dialog state may remain. A failure would let the UI remove or reconcile a book that still exists.
     */
    func testCommitNotifiesOnlySuccessfullyDeletedEpubsAndStopsOnFailure() {
        var state = EpubLibraryDeletionState()
        state.request([
            EpubLibraryDeletionCandidate(identifier: "first", title: "First"),
            EpubLibraryDeletionCandidate(identifier: "second", title: "Second"),
            EpubLibraryDeletionCandidate(identifier: "third", title: "Third"),
        ])
        var attempted: [String] = []
        var committed: [String] = []

        let error = state.commit(
            delete: { identifier in
                attempted.append(identifier)
                if identifier == "second" {
                    throw EpubLibraryDeletionTestError.injectedFailure
                }
            },
            onDeleted: { committed.append($0) }
        )

        XCTAssertEqual(error as? EpubLibraryDeletionTestError, .injectedFailure)
        XCTAssertEqual(attempted, ["first", "second"])
        XCTAssertEqual(committed, ["first"])
        XCTAssertFalse(state.isAwaitingConfirmation)
    }
}

/** Error used to prove failed EPUB storage commits never emit success callbacks. */
private enum EpubLibraryDeletionTestError: Error, Equatable {
    /// Deterministic failure raised for the second candidate.
    case injectedFailure
}
