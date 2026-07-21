import XCTest
@testable import BibleCore
@testable import BibleUI

/** Progress-ordering and cancellation coverage for parent-owned Daily Reading actions. */
final class DailyReadingActionExecutionTests: XCTestCase {
    /**
     Verifies a successful parent action marks progress only after the callback returns.

     Failure meaning:
     - a navigation/speech attempt can be counted before active-module mapping and action startup
       have actually succeeded.
     */
    @MainActor
    func testSuccessfulActionMarksOnlyAfterHandlerReturns() async throws {
        let request = try makeSpeakAllRequest()
        var events: [String] = []

        let result = await DailyReadingActionExecutor.execute(
            request,
            handler: { received in
                XCTAssertEqual(received, request)
                events.append("handled")
            },
            onSuccess: { events.append("marked") }
        )

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(events, ["handled", "marked"])
    }

    /**
     Verifies parent mapping/action failure remains visible and leaves progress untouched.

     Failure meaning:
     - an unmappable non-KJV range or failed speech start can still be marked read.
     */
    @MainActor
    func testFailedActionDoesNotMarkProgress() async throws {
        let request = try makeSpeakAllRequest()
        var didMark = false

        let result = await DailyReadingActionExecutor.execute(
            request,
            handler: { _ in throw DailyReadingExecutionFixtureError.mappingFailed },
            onSuccess: { didMark = true }
        )

        XCTAssertEqual(result, .failed("fixture mapping failed"))
        XCTAssertFalse(didMark)
    }

    /**
     Verifies a failed progress commit remains visible after the parent action succeeds.

     Failure meaning:
     - Read can dismiss or Speak can report completion after persistence or journaling failed.
     */
    @MainActor
    func testFailedProgressMutationDoesNotCompleteAction() async throws {
        let request = try makeSpeakAllRequest()

        let result = await DailyReadingActionExecutor.execute(
            request,
            handler: { _ in },
            onSuccess: {
                throw NSError(
                    domain: "DailyReadingActionExecutionTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "fixture persistence failed"]
                )
            }
        )

        XCTAssertEqual(result, .failed("fixture persistence failed"))
    }

    /**
     Verifies cancelling Speak All while the parent is suspended never marks any reading.

     Failure meaning:
     - dismissing Daily Reading can allow a late speech callback to mark every range complete.
     */
    @MainActor
    func testCancelledSpeakAllDoesNotMarkProgress() async throws {
        let request = try makeSpeakAllRequest()
        let started = expectation(description: "speech handler started")
        var didMark = false
        let task = Task { @MainActor in
            await DailyReadingActionExecutor.execute(
                request,
                handler: { _ in
                    started.fulfill()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                onSuccess: { didMark = true }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(didMark)
    }

    /**
     Verifies cancellation still wins when a parent handler suppresses its own cancellation error.

     Failure meaning:
     - a reader or speech adapter that finishes cleanup and returns normally after dismissal can
       cause every Speak All range to be marked despite the presentation no longer owning the work.
     */
    @MainActor
    func testCancelledActionDoesNotMarkWhenHandlerReturnsNormallyAfterCancellation() async throws {
        let request = try makeSpeakAllRequest()
        let started = expectation(description: "speech handler started")
        var didMark = false
        let task = Task { @MainActor in
            await DailyReadingActionExecutor.execute(
                request,
                handler: { _ in
                    started.fulfill()
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch is CancellationError {
                        // A parent may consume cancellation while stopping its playback resources.
                    }
                },
                onSuccess: { didMark = true }
            )
        }

        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(didMark)
    }

    /** Builds one three-range Speak All request through the production plan-canon parser. */
    private func makeSpeakAllRequest() throws -> DailyReadingActionRequest {
        try DailyReadingActionRequestFactory.makeRequest(
            planID: UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!,
            planCode: "speech-all",
            dayNumber: 3,
            assignment: ReadingPlanDayAssignment(rawValue: "Gen.1,Matt.1,Rev.22"),
            planVersification: "KJV",
            kind: .speak,
            readingNumbers: [1, 2, 3]
        )
    }
}

/** Deterministic parent failure used to verify visible Daily Reading error propagation. */
private enum DailyReadingExecutionFixtureError: LocalizedError {
    /// Active-module mapping failed before navigation or speech could begin.
    case mappingFailed

    /// Stable user-facing fixture message asserted by the executor test.
    var errorDescription: String? { "fixture mapping failed" }
}
