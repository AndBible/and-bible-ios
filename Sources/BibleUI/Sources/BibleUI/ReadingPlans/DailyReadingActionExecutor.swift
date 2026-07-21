// DailyReadingActionExecutor.swift -- Progress-safe daily-reading action execution

import BibleCore
import Foundation

/** Parent-reader callback that maps, validates, and performs one daily-reading action. */
public typealias DailyReadingActionHandler = @MainActor (
    DailyReadingActionRequest
) async throws -> Void

/** Supplies the optional raw JSword versification, throwing when the plan definition is missing. */
public typealias ReadingPlanVersificationResolver = @MainActor (String) throws -> String?

/** Observable terminal outcomes from one Daily Reading action attempt. */
enum DailyReadingActionExecutionResult: Equatable {
    /// Parent action succeeded and the completion mutation ran.
    case completed

    /// Task cancellation prevented progress mutation and user-facing failure.
    case cancelled

    /// Request construction or parent execution failed visibly without progress mutation.
    case failed(String)
}

/**
 Runs a parent-owned Daily Reading action before allowing progress mutation.

 Daily Reading must mark a reading only after reference resolution and navigation or speech starts.
 This helper makes that ordering explicit and checks cancellation again after the async parent
 callback, closing the race where a dismissed screen could otherwise mark progress from a late
 completion.
 */
@MainActor
enum DailyReadingActionExecutor {
    /**
     Executes one typed request and invokes `onSuccess` only after uncancelled success.

     - Parameters:
       - request: Exactly parsed plan-canon action request.
       - handler: Parent reader callback responsible for active-module mapping and action execution.
       - onSuccess: Throwing synchronous progress mutation to run after successful action completion.
     - Returns: Completed, cancelled, or visible failure outcome.
     - Side effects: Invokes the parent handler and may invoke the supplied progress mutation.
     - Failure modes: Missing handlers, handler failures, and progress-persistence failures become
       `.failed`; cancellation becomes `.cancelled` and never invokes `onSuccess`.
     */
    static func execute(
        _ request: DailyReadingActionRequest,
        handler: DailyReadingActionHandler?,
        onSuccess: () throws -> Void
    ) async -> DailyReadingActionExecutionResult {
        guard let handler else {
            return .failed(DailyReadingActionError.handlerUnavailable.localizedDescription)
        }
        do {
            try Task.checkCancellation()
            try await handler(request)
            try Task.checkCancellation()
            try onSuccess()
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
