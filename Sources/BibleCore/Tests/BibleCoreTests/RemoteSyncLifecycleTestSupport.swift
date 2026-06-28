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
