import Foundation
import XCTest
@testable import BibleUI

/** Verifies stable request identity, retry cancellation, and exactly-once terminal delivery. */
final class BibleReaderAwaitedSelectionRequestTests: XCTestCase {
    /** Cancellation follows a retry's latest claim and invalidates the initial attempt claim. */
    func testCancellationTargetsLatestRetryClaim() async {
        let request = BibleReaderAwaitedSelectionRequest()
        let callbacks = ClaimRecorder()
        let first = request.claim(generation: 10) { callbacks.record($0) }

        request.cancel()
        let retry = request.claim(generation: 11) { callbacks.record($0) }

        XCTAssertEqual(callbacks.generations, [10, 11])
        XCTAssertFalse(first.map { request.owns($0) } ?? true)
        XCTAssertTrue(retry.map { request.owns($0) } ?? false)
        let waiter = Task { await request.wait() }
        XCTAssertTrue(request.complete(.cancelled))
        XCTAssertFalse(request.complete(.accepted))
        let result = await waiter.value
        XCTAssertEqual(result, .cancelled)
    }

    /** A late task cancellation after terminal completion cannot enqueue controller cancellation. */
    func testLateCancellationAfterTerminalDoesNotInvokeAttemptCallback() async {
        let request = BibleReaderAwaitedSelectionRequest()
        let callbacks = ClaimRecorder()
        _ = request.claim(generation: 22) { callbacks.record($0) }
        let waiter = Task { await request.wait() }

        XCTAssertTrue(request.complete(.accepted))
        request.cancel()

        let result = await waiter.value
        XCTAssertEqual(result, .accepted)
        XCTAssertTrue(callbacks.generations.isEmpty)
    }

    /** The selected-key receipt belongs to this request and survives its terminal result. */
    func testCommittedKeyReceiptIsRequestLocal() async {
        let first = BibleReaderAwaitedSelectionRequest()
        let second = BibleReaderAwaitedSelectionRequest()
        first.recordCommittedKey("first")
        second.recordCommittedKey("second")
        let waiter = Task { await second.wait() }

        XCTAssertTrue(second.complete(.bridgeRejected))

        let result = await waiter.value
        XCTAssertEqual(result, .bridgeRejected)
        XCTAssertEqual(first.committedKey(), "first")
        XCTAssertEqual(second.committedKey(), "second")
    }
}

/** Lock-protected callback recorder used by cancellation tests crossing task boundaries. */
private final class ClaimRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    /// Snapshot of recorded generations in callback order.
    var generations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /** Records one cancellation claim without invoking any external side effect. */
    func record(_ claim: BibleReaderAwaitedSelectionRequest.Claim) {
        lock.lock()
        storage.append(claim.generation)
        lock.unlock()
    }
}
