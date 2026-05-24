// RemoteSyncBackgroundRefreshCoordinator.swift — Scheduled background refresh for remote sync

#if os(iOS)
import BackgroundTasks
import Foundation
import SwiftData

/**
 Describes one pending background-refresh request submitted to the system scheduler.

 The concrete scheduler wrapper converts this value into `BGAppRefreshTaskRequest`. Tests use the
 plain value directly so scheduling behavior can be asserted without touching the real
 `BGTaskScheduler`.
 */
struct RemoteSyncBackgroundRefreshRequest: Sendable, Equatable {
    /// Stable identifier declared in `Info.plist` for the refresh task.
    let identifier: String

    /// Earliest time the system may launch the refresh task.
    let earliestBeginDate: Date?

    /**
     Creates one background-refresh request value.

     - Parameters:
       - identifier: Stable identifier declared in `Info.plist`.
       - earliestBeginDate: Earliest time the system may launch the task.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(identifier: String, earliestBeginDate: Date?) {
        self.identifier = identifier
        self.earliestBeginDate = earliestBeginDate
    }
}

/**
 Mutable task handle exposed to the background-refresh coordinator.

 The production implementation wraps `BGAppRefreshTask`, while tests inject a lightweight fake so
 expiration and completion behavior can be asserted deterministically.
 */
protocol RemoteSyncBackgroundRefreshTaskHandling: AnyObject {
    /// System callback invoked when the background task is about to expire.
    var expirationHandler: (() -> Void)? { get set }

    /**
     Marks the background task as finished.

     - Parameter success: Whether the task completed successfully before expiration.
     - Side effects: Completes the underlying OS-managed task.
     - Failure modes: This helper cannot fail.
     */
    func setTaskCompleted(success: Bool)
}

/**
 Abstract scheduler used by the background-refresh coordinator.

 The live implementation delegates to `BGTaskScheduler`, while tests capture registrations and
 submitted requests in memory.
 */
protocol RemoteSyncBackgroundRefreshScheduling: AnyObject {
    /**
     Registers the launch handler for one refresh-task identifier.

     - Parameters:
       - identifier: Stable identifier declared in `Info.plist`.
       - launchHandler: Closure invoked when the system launches the registered task.
     - Returns: `true` when registration succeeded.
     - Side effects: Registers the identifier with the concrete scheduler.
     - Failure modes:
       - returns `false` when the scheduler rejects the registration
     */
    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any RemoteSyncBackgroundRefreshTaskHandling) -> Void
    ) -> Bool

    /**
     Submits one background-refresh request to the concrete scheduler.

     - Parameter request: Request describing when the task may run.
     - Side effects: Enqueues work with the concrete scheduler.
     - Throws: Scheduler-specific submission errors.
     */
    func submit(_ request: RemoteSyncBackgroundRefreshRequest) throws

    /**
     Cancels any pending task request for the supplied identifier.

     - Parameter identifier: Stable identifier previously submitted to the scheduler.
     - Side effects: Removes pending requests for the identifier from the concrete scheduler.
     - Failure modes: This helper cannot fail.
     */
    func cancel(taskRequestWithIdentifier identifier: String)
}

/**
 Live `BGAppRefreshTask` wrapper used by the scheduler bridge.
 */
final class LiveRemoteSyncBackgroundRefreshTask: RemoteSyncBackgroundRefreshTaskHandling {
    private let task: BGAppRefreshTask

    /**
     Wraps one system background-refresh task.

     - Parameter task: System task object delivered by `BGTaskScheduler`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(task: BGAppRefreshTask) {
        self.task = task
    }

    /// System callback invoked when the background task is about to expire.
    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    /**
     Marks the system task as completed.

     - Parameter success: Whether the task completed successfully before expiration.
     - Side effects: Forwards completion to `BGAppRefreshTask`.
     - Failure modes: This helper cannot fail.
     */
    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

/**
 Live scheduler bridge backed by `BGTaskScheduler.shared`.
 */
final class LiveRemoteSyncBackgroundRefreshScheduler: RemoteSyncBackgroundRefreshScheduling {
    /// Shared scheduler bridge used by the app.
    static let shared = LiveRemoteSyncBackgroundRefreshScheduler()

    private init() {}

    /**
     Registers a system background-refresh launch handler.

     - Parameters:
       - identifier: Stable identifier declared in `Info.plist`.
       - launchHandler: Closure invoked when the system launches the registered task.
     - Returns: `true` when registration succeeded.
     - Side effects: Registers the identifier with `BGTaskScheduler.shared`.
     - Failure modes:
       - returns `false` when `BGTaskScheduler` rejects duplicate or invalid registrations
     */
    func register(
        forTaskWithIdentifier identifier: String,
        launchHandler: @escaping (any RemoteSyncBackgroundRefreshTaskHandling) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            launchHandler(LiveRemoteSyncBackgroundRefreshTask(task: refreshTask))
        }
    }

    /**
     Submits one app-refresh request to `BGTaskScheduler`.

     - Parameter request: Request describing when the task may run.
     - Side effects: Enqueues a `BGAppRefreshTaskRequest` with the system scheduler.
     - Throws: Re-throws submission failures from `BGTaskScheduler`.
     */
    func submit(_ request: RemoteSyncBackgroundRefreshRequest) throws {
        let taskRequest = BGAppRefreshTaskRequest(identifier: request.identifier)
        taskRequest.earliestBeginDate = request.earliestBeginDate
        try BGTaskScheduler.shared.submit(taskRequest)
    }

    /**
     Cancels any pending system request for the supplied identifier.

     - Parameter identifier: Stable identifier previously submitted to the scheduler.
     - Side effects: Removes pending requests for the identifier from `BGTaskScheduler.shared`.
     - Failure modes: This helper cannot fail.
     */
    func cancel(taskRequestWithIdentifier identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/**
 Ensures background tasks are only completed once.

 Expiration handlers and async completion paths can race. This actor keeps the coordinator from
 calling `setTaskCompleted(success:)` multiple times for the same task.
 */
actor RemoteSyncBackgroundRefreshCompletionState {
    private var didComplete = false

    /**
     Completes the task once and ignores later attempts.

     - Parameters:
       - task: Background task handle to complete.
       - success: Completion status to report.
     - Side effects: Calls `setTaskCompleted(success:)` at most once.
     - Failure modes: This helper cannot fail.
     */
    func completeIfNeeded(
        task: any RemoteSyncBackgroundRefreshTaskHandling,
        success: Bool
    ) {
        guard !didComplete else {
            return
        }

        didComplete = true
        task.setTaskCompleted(success: success)
    }
}

/**
 Coordinates scheduled `BGAppRefreshTask` execution for remote sync backends.

 This coordinator reuses the existing `RemoteSyncLifecycleService` instead of introducing a second
 synchronization path. It schedules refresh work using Android's stored sync interval, skips
 scheduling when the selected backend is iCloud or no remote categories are enabled, and routes
 the launched task back through `synchronizeIfNeeded(force: false)`.

 Data dependencies:
 - `ModelContainer` supplies a fresh `ModelContext` for reading remote sync settings
 - `RemoteSyncSettingsStore` provides the selected backend, enabled categories, and sync interval
 - `RemoteSyncBackgroundRefreshScheduling` abstracts `BGTaskScheduler` for testability
 - `synchronizeIfNeeded` bridges to `RemoteSyncLifecycleService`

 Side effects:
 - registers a background refresh identifier with the system scheduler
 - submits and cancels pending refresh requests as remote sync configuration changes
 - launches lifecycle-driven remote synchronization when the system wakes the app

 Failure modes:
 - scheduler registration or submission failures are swallowed because background refresh is
   best-effort and must not block the foreground app
 - disabled or incomplete remote-sync configuration cancels pending requests instead of scheduling
 - expired tasks complete with `success = false` and rely on the next schedule attempt
 */
public final class RemoteSyncBackgroundRefreshCoordinator {
    /// Stable app-refresh identifier declared in `Info.plist`.
    public static let defaultTaskIdentifier = "org.andbible.ios.remote-sync-refresh"

    private let modelContainer: ModelContainer
    private let taskIdentifier: String
    private let scheduler: any RemoteSyncBackgroundRefreshScheduling
    private let nowProvider: () -> Date
    private let synchronizeIfNeeded: @MainActor (Bool) async -> Bool
    private var isRegistered = false

    /**
     Creates a background-refresh coordinator.

     - Parameters:
       - modelContainer: Model container used to read persisted remote sync settings.
       - taskIdentifier: Stable refresh identifier declared in `Info.plist`.
       - synchronizeIfNeeded: Lifecycle-sync entry point used when the task launches.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public convenience init(
        modelContainer: ModelContainer,
        taskIdentifier: String = defaultTaskIdentifier,
        synchronizeIfNeeded: @escaping @MainActor (Bool) async -> Bool
    ) {
        self.init(
            modelContainer: modelContainer,
            taskIdentifier: taskIdentifier,
            scheduler: LiveRemoteSyncBackgroundRefreshScheduler.shared,
            nowProvider: Date.init,
            synchronizeIfNeeded: synchronizeIfNeeded
        )
    }

    /**
     Creates a background-refresh coordinator with injected scheduling dependencies.

     Tests use this initializer to supply an in-memory scheduler and a deterministic clock without
     widening the public API surface exposed to app code.

     - Parameters:
       - modelContainer: Model container used to read persisted remote sync settings.
       - taskIdentifier: Stable refresh identifier declared in `Info.plist`.
       - scheduler: Concrete scheduler bridge. Tests inject fakes.
       - nowProvider: Clock used to compute `earliestBeginDate`.
       - synchronizeIfNeeded: Lifecycle-sync entry point used when the task launches.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(
        modelContainer: ModelContainer,
        taskIdentifier: String = defaultTaskIdentifier,
        scheduler: any RemoteSyncBackgroundRefreshScheduling,
        nowProvider: @escaping () -> Date = Date.init,
        synchronizeIfNeeded: @escaping @MainActor (Bool) async -> Bool
    ) {
        self.modelContainer = modelContainer
        self.taskIdentifier = taskIdentifier
        self.scheduler = scheduler
        self.nowProvider = nowProvider
        self.synchronizeIfNeeded = synchronizeIfNeeded
    }

    /**
     Registers the system launch handler once during app startup.

     - Side effects: Registers `taskIdentifier` with the concrete scheduler.
     - Failure modes:
       - scheduler rejection is swallowed so the foreground app can continue operating
     */
    public func register() {
        guard !isRegistered else {
            return
        }

        isRegistered = scheduler.register(forTaskWithIdentifier: taskIdentifier) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }

            Task {
                await self.handle(task: task)
            }
        }
    }

    /**
     Schedules the next best-effort refresh pass when remote sync is configured.

     The request uses Android's stored remote sync interval rather than a hard-coded iOS timer so
     imported Android preferences keep the same effective cadence.

     - Side effects:
       - cancels any stale pending request for `taskIdentifier`
       - submits a new app-refresh request when a non-iCloud backend has at least one enabled
         category
     - Failure modes:
       - disabled or incomplete remote-sync configuration cancels pending requests
       - scheduler submission failures are swallowed because background refresh is best-effort
     */
    public func scheduleNextRefreshIfNeeded() {
        let remoteSettingsStore = makeRemoteSettingsStore()
        guard isBackgroundRefreshConfigured(using: remoteSettingsStore) else {
            scheduler.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }

        scheduler.cancel(taskRequestWithIdentifier: taskIdentifier)

        let earliestBeginDate = nowProvider().addingTimeInterval(
            TimeInterval(max(remoteSettingsStore.remoteSyncIntervalSeconds, 0))
        )
        let request = RemoteSyncBackgroundRefreshRequest(
            identifier: taskIdentifier,
            earliestBeginDate: earliestBeginDate
        )

        try? scheduler.submit(request)
    }

    /**
     Cancels any pending scheduled refresh for the remote sync task identifier.

     - Side effects: Removes pending requests for `taskIdentifier` from the scheduler.
     - Failure modes: This helper cannot fail.
     */
    public func cancelScheduledRefresh() {
        scheduler.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /**
     Executes one launched background-refresh task.

     - Parameter task: System task handle to manage.
     - Side effects:
       - schedules the next refresh attempt before work begins
       - routes the launched work through `synchronizeIfNeeded(force: false)`
       - installs an expiration handler that cancels the in-flight task and marks it incomplete
     - Failure modes:
       - expiration completes the task with `success = false`
       - synchronization no-ops still complete with `success = true` because the background
         refresh attempt itself finished cleanly
     */
    private func handle(task: any RemoteSyncBackgroundRefreshTaskHandling) async {
        scheduleNextRefreshIfNeeded()

        let completionState = RemoteSyncBackgroundRefreshCompletionState()
        let synchronizationTask = Task { [synchronizeIfNeeded] in
            _ = await synchronizeIfNeeded(false)
            guard !Task.isCancelled else {
                return
            }
            await completionState.completeIfNeeded(task: task, success: true)
        }

        task.expirationHandler = {
            synchronizationTask.cancel()
            Task {
                await completionState.completeIfNeeded(task: task, success: false)
            }
        }

        _ = await synchronizationTask.value
    }

    /**
     Returns whether remote background refresh should be scheduled at all.

     - Parameter remoteSettingsStore: Persisted remote sync settings.
     - Returns: `true` when a non-iCloud backend has at least one enabled category.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func isBackgroundRefreshConfigured(
        using remoteSettingsStore: RemoteSyncSettingsStore
    ) -> Bool {
        guard remoteSettingsStore.selectedBackend != .iCloud else {
            return false
        }

        return RemoteSyncCategory.activeSyncCases.contains {
            remoteSettingsStore.isSyncEnabled(for: $0)
        }
    }

    /**
     Creates a fresh remote settings store from the app model container.

     - Returns: Remote settings store backed by a fresh `ModelContext`.
     - Side effects: Creates a new `ModelContext` and `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
    private func makeRemoteSettingsStore() -> RemoteSyncSettingsStore {
        let modelContext = ModelContext(modelContainer)
        let settingsStore = SettingsStore(modelContext: modelContext)
        return RemoteSyncSettingsStore(settingsStore: settingsStore)
    }
}
#endif
