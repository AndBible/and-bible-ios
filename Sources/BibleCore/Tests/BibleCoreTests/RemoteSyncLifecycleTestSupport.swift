import Foundation
import SwiftData
@testable import BibleCore

/**
 Creates a deterministic lifecycle synchronization report for remote-sync lifecycle tests.

 - Parameter category: Sync category the fake report should describe.
 - Returns: A completed synchronization report with stable bootstrap metadata and timestamps.
 - Side effects: none.
 - Failure modes: none.
 */
func makeLifecycleSyncReport(for category: RemoteSyncCategory) -> RemoteSyncCategorySynchronizationReport {
    RemoteSyncCategorySynchronizationReport(
        category: category,
        bootstrapState: RemoteSyncBootstrapState(
            syncFolderID: "/sync/\(category.rawValue)",
            deviceFolderID: "/sync/\(category.rawValue)/device",
            secretFileName: "device-known-ios"
        ),
        initialRestoreReport: nil,
        patchReplayReport: nil,
        patchUploadReport: nil,
        discoveredPatchCount: 0,
        lastPatchWritten: nil,
        lastSynchronized: 1_000
    )
}

/**
 Test double for `RemoteSyncCategorySynchronizing`.

 The lifecycle runner only needs category synchronization plus the auto-create branch, so this fake
 records both call paths and returns preloaded outcomes without touching WebDAV transport.
 */
@MainActor
final class MockRemoteSyncLifecycleSynchronizer: RemoteSyncCategorySynchronizing {
    /// Preloaded outcomes returned from `synchronize(_:modelContext:settingsStore:)`.
    var synchronizeResults: [RemoteSyncCategory: RemoteSyncSynchronizationOutcome] = [:]

    /// Preloaded reports returned from `adoptRemoteFolderAndSynchronize(...)`.
    var adoptResults: [RemoteSyncCategory: RemoteSyncCategorySynchronizationReport] = [:]

    /// Preloaded reports returned from `createRemoteFolderAndSynchronize(...)`.
    var createResults: [RemoteSyncCategory: RemoteSyncCategorySynchronizationReport] = [:]

    /// Categories passed through the main synchronization entry point.
    private(set) var synchronizeCalls: [RemoteSyncCategory] = []

    /// Categories passed through the adopt-existing-folder recovery path.
    private(set) var adoptCalls: [RemoteSyncCategory] = []

    /// Categories passed through the auto-create recovery path.
    private(set) var createCalls: [RemoteSyncCategory] = []

    /**
     Returns the preloaded outcome for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization outcome for the category.
     - Side effects: Appends the category to `synchronizeCalls`.
     - Failure modes: Missing preloaded outcomes trap the test with precondition semantics.
     */
    func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncSynchronizationOutcome {
        synchronizeCalls.append(category)
        guard let result = synchronizeResults[category] else {
            preconditionFailure("Missing synchronize result for \(category)")
        }
        return result
    }

    /**
     Returns the preloaded adopt-existing-folder report for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - remoteFolderID: Existing remote folder identifier chosen by the user.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization report for the category.
     - Side effects: Appends the category to `adoptCalls`.
     - Failure modes: Missing preloaded reports trap the test with precondition semantics.
     */
    func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        adoptCalls.append(category)
        guard let result = adoptResults[category] else {
            preconditionFailure("Missing adopt result for \(category)")
        }
        return result
    }

    /**
     Returns the preloaded auto-create report for a category and records the call.

     - Parameters:
       - category: Logical sync category requested by the lifecycle runner.
       - replacingRemoteFolderID: Optional folder identifier that would be deleted first in
         production.
       - modelContext: Unused test context supplied by the caller.
       - settingsStore: Unused test settings store supplied by the caller.
     - Returns: Preloaded synchronization report for the category.
     - Side effects: Appends the category to `createCalls`.
     - Failure modes: Missing preloaded reports trap the test with precondition semantics.
     */
    func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        createCalls.append(category)
        guard let result = createResults[category] else {
            preconditionFailure("Missing create result for \(category)")
        }
        return result
    }
}

/**
 Suspends the first lifecycle category operation until a test explicitly releases it.

 The main-actor fake exposes continuation-driven observation so retirement tests can prove a drain
 boundary without sleeps or polling. It records every attempted category and returns successful
 reports or a configured deterministic error after release; interactive entry points are unsupported
 because these tests exercise the shared admission boundary through the lifecycle sweep.
 */
@MainActor
final class SuspendedRemoteSyncLifecycleSynchronizer: RemoteSyncCategorySynchronizing {
    /// Deterministic failure available for exercising retirement after a suspended throw.
    enum TestError: Error {
        /// The held category fails after its continuation is released.
        case failureAfterRelease
    }

    /// Categories admitted by the lifecycle service, in execution order.
    private(set) var synchronizeCalls: [RemoteSyncCategory] = []

    /// When true, the first held category throws after explicit release.
    var failsAfterRelease = false

    private var shouldSuspendNextCall = true
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /**
     Waits until the synchronizer has entered its suspended category operation.

     - Side effects: Retains the caller continuation until synchronization starts.
     - Failure modes: This helper does not time out; a missing production call leaves the test pending.
     */
    func waitUntilStarted() async {
        if releaseContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    /**
     Releases the suspended category operation exactly once.

     - Side effects: Resumes and clears the retained synchronization continuation.
     - Failure modes: Calling before suspension or after release is a no-op.
     */
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /**
     Records a category, suspends the first call, and returns a deterministic success report.

     - Parameters:
       - category: Category admitted by the lifecycle service.
       - modelContext: Unused context whose lifetime is intentionally held across suspension.
       - settingsStore: Unused store whose lifetime is intentionally held across suspension.
     - Returns: A successful synchronization outcome after explicit release.
     - Side effects: Records the category and retains a continuation for the first call.
     - Failure modes: Throws ``TestError.failureAfterRelease`` when configured. Task cancellation does
       not release the continuation, matching the noncooperative-I/O boundary under test.
     */
    func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncSynchronizationOutcome {
        synchronizeCalls.append(category)
        if shouldSuspendNextCall {
            shouldSuspendNextCall = false
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                let waiters = startedWaiters
                startedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
            if failsAfterRelease {
                throw TestError.failureAfterRelease
            }
        }
        return .synchronized(makeLifecycleSyncReport(for: category))
    }

    /** Unsupported interactive path for lifecycle retirement tests. */
    func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        preconditionFailure("Interactive adoption is outside this fake's contract")
    }

    /** Unsupported interactive path for lifecycle retirement tests. */
    func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        preconditionFailure("Interactive creation is outside this fake's contract")
    }
}

/**
 Continuation-controlled manual operation used to verify lifecycle admission and draining.

 The helper is main-actor isolated like the production closure. It records invocation, signals exact
 entry without polling, and ignores cancellation until explicitly released to model noncooperative
 remote or persistence work.
 */
@MainActor
final class SuspendedManualRemoteSyncOperation {
    /// Number of times the operation closure entered.
    private(set) var invocationCount = 0

    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /**
     Runs and suspends the manual operation until explicit release.

     - Side effects: Increments ``invocationCount`` and retains a continuation.
     - Failure modes: Cancellation does not release the operation; the test must call ``release()``.
     */
    func run() async {
        invocationCount += 1
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            let waiters = startedWaiters
            startedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /** Waits until ``run()`` has retained its continuation, without polling or wall-clock delay. */
    func waitUntilStarted() async {
        if releaseContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    /** Releases the admitted manual operation exactly once; other calls are no-ops. */
    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

#if os(iOS)
/**
 In-memory scheduler double for `RemoteSyncBackgroundRefreshCoordinator` tests.

 The fake captures registrations, submitted requests, and cancellations so tests can verify the
 coordinator's scheduling policy without talking to `BGTaskScheduler`.
 */
final class FakeRemoteSyncBackgroundRefreshScheduler: RemoteSyncBackgroundRefreshScheduling {
    /// Identifier most recently registered with the fake scheduler.
    private(set) var registeredIdentifier: String?

    /// Launch handler installed by the coordinator under test.
    var launchHandler: ((any RemoteSyncBackgroundRefreshTaskHandling) -> Void)?

    /// Requests submitted through the fake scheduler.
    private(set) var submittedRequests: [RemoteSyncBackgroundRefreshRequest] = []

    /// Identifiers cancelled through the fake scheduler.
    private(set) var cancelledIdentifiers: [String] = []

    /**
     Captures the registration request and stores the launch handler.

     - Parameters:
       - identifier: Stable task identifier supplied by the coordinator.
       - launchHandler: Handler invoked by tests to simulate a launched task.
     - Returns: `true` so registration succeeds in tests.
     - Side effects: Stores the identifier and launch handler for later assertions.
     - Failure modes: This helper cannot fail.
     */
    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any RemoteSyncBackgroundRefreshTaskHandling) -> Void
    ) -> Bool {
        registeredIdentifier = identifier
        self.launchHandler = launchHandler
        return true
    }

    /**
     Records one submitted background refresh request.

     - Parameter request: Request supplied by the coordinator.
     - Side effects: Appends the request to `submittedRequests`.
     - Failure modes: This helper cannot fail.
     */
    func submit(_ request: RemoteSyncBackgroundRefreshRequest) throws {
        submittedRequests.append(request)
    }

    /**
     Records one cancellation request.

     - Parameter identifier: Stable task identifier cancelled by the coordinator.
     - Side effects: Appends the identifier to `cancelledIdentifiers`.
     - Failure modes: This helper cannot fail.
     */
    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelledIdentifiers.append(identifier)
    }
}

/**
 In-memory task double for background-refresh coordinator tests.

 Tests use this handle to observe completion state and manually trigger the expiration callback.
 */
final class FakeRemoteSyncBackgroundRefreshTask: RemoteSyncBackgroundRefreshTaskHandling {
    /// Callback fired when the coordinator installs an expiration handler.
    var onExpirationHandlerSet: (() -> Void)?

    /// Callback fired when the coordinator completes the task.
    var onCompletion: ((Bool) -> Void)?

    /// Completion statuses recorded for this fake task.
    private(set) var completions: [Bool] = []

    /// Expiration handler installed by the coordinator.
    var expirationHandler: (() -> Void)? {
        didSet {
            if expirationHandler != nil {
                onExpirationHandlerSet?()
            }
        }
    }

    /**
     Records one task completion result.

     - Parameter success: Completion status supplied by the coordinator.
     - Side effects:
       - appends the status to `completions`
       - invokes `onCompletion`
     - Failure modes: This helper cannot fail.
     */
    func setTaskCompleted(success: Bool) {
        completions.append(success)
        onCompletion?(success)
    }
}
#endif
