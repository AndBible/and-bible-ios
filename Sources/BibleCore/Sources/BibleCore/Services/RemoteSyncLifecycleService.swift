// RemoteSyncLifecycleService.swift — Foreground/background orchestration for remote sync backends

import Foundation
import SwiftData

/**
 Abstraction over the category-scoped synchronization coordinator used by lifecycle-driven sync.

 The production implementation is `RemoteSyncSynchronizationService`. Tests inject lightweight
 fakes so lifecycle policy can be exercised without touching remote transport or SQLite staging.
 */
@MainActor
public protocol RemoteSyncCategorySynchronizing: AnyObject {
    /**
     Runs one synchronization pass for a category and reports whether more user input is required.

     - Parameters:
       - category: Logical sync category to process.
       - modelContext: SwiftData context used for restore, patch replay, and outbound export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Synchronization outcome for the category.
     - Side Effects: May perform remote I/O and mutate local SwiftData plus local-only sync metadata.
     - Throws: Re-throws synchronization, restore, or transport failures from the concrete service.
     */
    func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncSynchronizationOutcome

    /**
     Creates a fresh remote folder for a category and immediately synchronizes against it.

     Android does this automatically when no same-named remote folder exists. The lifecycle runner
     preserves that behavior so steady-state sync can recover from a missing remote folder without
     forcing the user back through settings.

     - Parameters:
       - category: Logical sync category to create remotely.
       - replacingRemoteFolderID: Optional pre-existing remote folder that should be deleted first.
       - modelContext: SwiftData context used for restore, patch replay, and outbound export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Successful synchronization summary for the created remote folder.
     - Side Effects: Performs remote folder creation/deletion and may mutate local SwiftData.
     - Throws: Re-throws bootstrap, upload, or synchronization failures from the concrete service.
     */
    func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport

    /**
     Adopts an existing remote folder for a category and immediately synchronizes against it.

     - Parameters:
       - category: Logical sync category to adopt remotely.
       - remoteFolderID: Existing remote folder identifier chosen by the user.
       - modelContext: SwiftData context used for restore, patch replay, and outbound export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Successful synchronization summary for the adopted remote folder.
     - Side Effects: Performs remote download/restore work and may mutate local SwiftData.
     - Throws: Re-throws bootstrap, restore, or synchronization failures from the concrete service.
     */
    func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport
}

extension RemoteSyncSynchronizationService: RemoteSyncCategorySynchronizing {
    /**
     Bridges the lifecycle protocol onto the schema-default synchronization entry point.

     - Parameters:
       - category: Logical sync category to process.
       - modelContext: SwiftData context used for restore, replay, and export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Synchronization outcome for the category.
     - Side Effects: Delegates to `RemoteSyncSynchronizationService.synchronize`.
     - Failure modes: Re-throws synchronization failures from the underlying service.
     */
    public func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncSynchronizationOutcome {
        try await synchronize(
            category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: 1
        )
    }

    /**
     Bridges the lifecycle protocol onto the schema-default auto-create synchronization path.

     - Parameters:
       - category: Logical sync category to create remotely.
       - replacingRemoteFolderID: Optional pre-existing remote folder to delete before recreation.
       - modelContext: SwiftData context used for restore, replay, and export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Successful synchronization summary for the created remote folder.
     - Side Effects: Delegates to `RemoteSyncSynchronizationService.createRemoteFolderAndSynchronize`.
     - Failure modes: Re-throws bootstrap, upload, and synchronization failures from the underlying service.
     */
    public func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        try await createRemoteFolderAndSynchronize(
            for: category,
            replacingRemoteFolderID: replacingRemoteFolderID,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: 1
        )
    }

    /**
     Bridges the lifecycle protocol onto the schema-default adopt-and-synchronize path.

     - Parameters:
       - category: Logical sync category to adopt remotely.
       - remoteFolderID: Existing remote folder identifier chosen by the user.
       - modelContext: SwiftData context used for restore, replay, and export work.
       - settingsStore: Local settings store scoped to the same `modelContext`.
     - Returns: Successful synchronization summary for the adopted remote folder.
     - Side Effects: Delegates to `RemoteSyncSynchronizationService.adoptRemoteFolderAndSynchronize`.
     - Failure modes: Re-throws bootstrap, restore, and synchronization failures from the underlying service.
     */
    public func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        try await adoptRemoteFolderAndSynchronize(
            for: category,
            remoteFolderID: remoteFolderID,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: 1
        )
    }
}

/**
 Coordinates Android-style remote sync from app lifecycle events instead of only from settings.

 Android starts a forced sync when the main activity comes to the foreground, stops periodic sync
 when the app backgrounds, and performs one final forced sync while backgrounding. This service
 mirrors that policy for iOS's remote sync backends while leaving CloudKit untouched.

 Data dependencies:
 - `ModelContainer` supplies fresh `ModelContext` instances for each sync pass
 - `RemoteSyncSettingsStore` supplies the active backend, backend-specific credentials, enabled
   categories, device identifier, global throttling timestamp, and sync interval
 - `SynchronizationServiceFactory` turns persisted backend settings into a concrete category
   synchronizer for the currently selected remote backend

 Side effects:
 - starts and stops an in-process periodic polling task while the app scene is active
 - performs forced and throttled synchronization passes for enabled remote-sync categories
 - updates Android's `globalLastSynchronized` key after successful lifecycle-driven passes
 - invokes optional callbacks when categories synchronize, require user interaction, or fail

 Failure modes:
 - missing or invalid remote configuration short-circuits the lifecycle pass without throwing
 - categories that require adopt-versus-create user input are surfaced through `onInteractionRequired`
   and skipped for that pass
 - category-specific synchronization errors are reported through `onCategoryError` and do not abort
   later categories in the same pass

 Concurrency:
 - this type is main-actor isolated because `ModelContext` and `SettingsStore` are not `Sendable`
 - the periodic task hops back to the main actor for each synchronization pass
 */
@MainActor
public final class RemoteSyncLifecycleService {
    /// Factory used to build the concrete synchronization service from persisted remote settings.
    public typealias SynchronizationServiceFactory =
        (_ remoteSettingsStore: RemoteSyncSettingsStore) throws -> any RemoteSyncCategorySynchronizing

    /// Factory used to build remote-sync settings stores for fresh per-pass `SettingsStore` instances.
    public typealias RemoteSettingsStoreFactory = (_ settingsStore: SettingsStore) -> RemoteSyncSettingsStore

    private let modelContainer: ModelContainer
    private let bundleIdentifier: String
    private let synchronizationServiceFactory: SynchronizationServiceFactory
    private let remoteSettingsStoreFactory: RemoteSettingsStoreFactory
    private let networkAvailableProvider: () -> Bool
    private let pollIntervalNanoseconds: UInt64
    private let nowProvider: () -> Int64
    private let sleep: @Sendable (UInt64) async -> Void

    private var periodicTask: Task<Void, Never>?
    private var isSynchronizing = false

    /// Invoked after one category completed a successful ready-state synchronization pass.
    public var onCategorySynchronized: ((RemoteSyncCategorySynchronizationReport) -> Void)?

    /// Invoked when a category needs adopt-versus-create UI that the lifecycle runner cannot supply.
    public var onInteractionRequired: ((RemoteSyncCategory, RemoteSyncSynchronizationOutcome) -> Void)?

    /// Invoked when one category throws during lifecycle-driven synchronization.
    public var onCategoryError: ((RemoteSyncCategory, Error) -> Void)?

    /**
     Creates a lifecycle-driven remote-sync orchestrator.

     - Parameters:
       - modelContainer: Model container used to create fresh `ModelContext` instances per pass.
       - bundleIdentifier: App bundle identifier used for Android-style remote folder naming.
       - synchronizationServiceFactory: Optional factory used to build the concrete synchronization
         coordinator from persisted backend settings. Tests can inject fakes; production defaults to
         `RemoteSyncSynchronizationServiceFactory`.
       - remoteSettingsStoreFactory: Optional factory used to build `RemoteSyncSettingsStore`
         instances for each fresh `SettingsStore`. Tests can inject a shared secret store while
         production defaults to the standard persisted settings plus Keychain-backed secrets.
       - networkAvailableProvider: Reports whether lifecycle sync should attempt remote work.
       - pollIntervalNanoseconds: Delay between periodic foreground sync checks.
       - nowProvider: Millisecond clock used for Android-compatible `globalLastSynchronized`.
       - sleep: Suspends the periodic loop between checks. Tests can inject deterministic behavior.
     - Side Effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        modelContainer: ModelContainer,
        bundleIdentifier: String,
        synchronizationServiceFactory: SynchronizationServiceFactory? = nil,
        remoteSettingsStoreFactory: RemoteSettingsStoreFactory? = nil,
        networkAvailableProvider: @escaping () -> Bool = { true },
        pollIntervalNanoseconds: UInt64 = 60 * 1_000_000_000,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        },
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.modelContainer = modelContainer
        self.bundleIdentifier = bundleIdentifier
        self.synchronizationServiceFactory = synchronizationServiceFactory ?? { remoteSettingsStore in
            try RemoteSyncSynchronizationServiceFactory(
                bundleIdentifier: bundleIdentifier
            )
            .makeSynchronizationService(using: remoteSettingsStore)
        }
        self.remoteSettingsStoreFactory = remoteSettingsStoreFactory ?? { settingsStore in
            RemoteSyncSettingsStore(settingsStore: settingsStore)
        }
        self.networkAvailableProvider = networkAvailableProvider
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.nowProvider = nowProvider
        self.sleep = sleep
    }

    /**
     Mirrors Android's foreground entry path: run an immediate sync, then start periodic polling.

     - Returns: `true` when at least one category finished a successful synchronization pass.
     - Side Effects:
       - performs an immediate forced synchronization pass
       - starts the periodic foreground sync loop when it is not already running
     - Failure modes:
       - invalid or incomplete remote configuration causes the immediate pass to short-circuit
         without failing the app scene transition
     */
    @discardableResult
    public func sceneDidBecomeActive() async -> Bool {
        let didSynchronize = await synchronizeIfNeeded(force: true)
        if isLifecycleSyncConfigured() {
            startPeriodicSync()
        } else {
            stopPeriodicSync()
        }
        return didSynchronize
    }

    /**
     Mirrors Android's backgrounding path: stop periodic sync and force one last sync attempt.

     - Returns: `true` when at least one category finished a successful synchronization pass.
     - Side Effects:
       - cancels the periodic foreground sync loop
       - performs a forced synchronization pass for enabled remote-sync categories
     - Failure modes:
       - invalid or incomplete remote configuration causes the background pass to short-circuit
         without failing app backgrounding
     */
    @discardableResult
    public func sceneDidEnterBackground() async -> Bool {
        stopPeriodicSync()
        return await synchronizeIfNeeded(force: true)
    }

    /**
     Stops the periodic foreground polling loop without running an extra synchronization pass.

     - Side Effects: Cancels the in-memory polling task when present.
     - Failure modes: This helper cannot fail.
     */
    public func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /**
     Runs one lifecycle-driven synchronization sweep when configuration and throttling allow it.

     - Parameter force: Whether the pass should bypass Android's `globalLastSynchronized` interval gate.
     - Returns: `true` when at least one category completed a successful synchronization pass.
     - Side Effects:
       - may perform remote I/O and mutate local SwiftData through category synchronization services
       - updates Android's `globalLastSynchronized` key after successful lifecycle-driven work
       - invokes user-supplied callbacks for success, interaction-required, and error outcomes
     - Failure modes:
       - invalid or incomplete remote configuration short-circuits the pass and returns `false`
       - overlapping calls return `false` instead of re-entering synchronization
     */
    @discardableResult
    public func synchronizeIfNeeded(force: Bool) async -> Bool {
        guard !isSynchronizing else {
            return false
        }

        let modelContext = ModelContext(modelContainer)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let remoteSettingsStore = remoteSettingsStoreFactory(settingsStore)

        guard remoteSettingsStore.selectedBackend != .iCloud,
              networkAvailableProvider() else {
            return false
        }

        let enabledCategories = enabledCategories(using: remoteSettingsStore)
        guard !enabledCategories.isEmpty else {
            return false
        }

        guard force || shouldRunPeriodicPass(using: remoteSettingsStore, now: nowProvider()) else {
            return false
        }

        guard let synchronizer = makeSynchronizer(using: remoteSettingsStore) else {
            return false
        }

        isSynchronizing = true
        defer { isSynchronizing = false }

        let now = nowProvider()
        var synchronizedAnyCategory = false

        for category in enabledCategories {
            do {
                let outcome = try await synchronizer.synchronize(
                    category,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )

                switch outcome {
                case .synchronized(let report):
                    synchronizedAnyCategory = true
                    onCategorySynchronized?(report)
                case .requiresRemoteCreation:
                    let report = try await synchronizer.createRemoteFolderAndSynchronize(
                        for: category,
                        replacingRemoteFolderID: nil,
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                    synchronizedAnyCategory = true
                    onCategorySynchronized?(report)
                case .requiresRemoteAdoption:
                    onInteractionRequired?(category, outcome)
                }
            } catch {
                onCategoryError?(category, error)
            }
        }

        if synchronizedAnyCategory {
            remoteSettingsStore.globalLastSynchronized = now
        }

        return synchronizedAnyCategory
    }

    /**
     Continues lifecycle-driven sync after the user chose to adopt an existing remote folder.

     Android surfaces this decision from `CloudSync.initializeSync()` even during lifecycle-driven
     sync started from `MainBibleActivity`. iOS exposes the same continuation hook so the app shell
     can present the two-step confirmation flow outside the settings screen and then resume sync.

     - Parameter candidate: Remote folder candidate the user chose to adopt.
     - Returns: `true` when the adopted remote folder synchronized successfully.
     - Side Effects:
       - performs remote download/restore work through the category synchronization service
       - updates Android's `globalLastSynchronized` key on success
       - invokes the standard success or error callbacks
     - Failure modes:
       - invalid or incomplete remote-backend configuration returns `false`
       - overlapping sync operations return `false` instead of re-entering synchronization
       - transport or restore failures are reported through `onCategoryError` and return `false`
     */
    @discardableResult
    public func adoptRemoteFolderAndSynchronize(
        _ candidate: RemoteSyncBootstrapCandidate
    ) async -> Bool {
        await performInteractiveSynchronization(for: candidate.category) { synchronizer, modelContext, settingsStore in
            try await synchronizer.adoptRemoteFolderAndSynchronize(
                for: candidate.category,
                remoteFolderID: candidate.remoteFolderID,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
    }

    /**
     Continues lifecycle-driven sync after the user chose to replace an existing remote folder.

     - Parameter candidate: Remote folder candidate the user chose to replace with local content.
     - Returns: `true` when the replacement remote folder synchronized successfully.
     - Side Effects:
       - deletes or recreates the conflicting remote folder through the category synchronization service
       - uploads a new initial backup before ready-state synchronization continues
       - updates Android's `globalLastSynchronized` key on success
       - invokes the standard success or error callbacks
     - Failure modes:
       - invalid or incomplete remote-backend configuration returns `false`
       - overlapping sync operations return `false` instead of re-entering synchronization
       - bootstrap, upload, or synchronization failures are reported through `onCategoryError` and return `false`
     */
    @discardableResult
    public func replaceRemoteFolderAndSynchronize(
        _ candidate: RemoteSyncBootstrapCandidate
    ) async -> Bool {
        await performInteractiveSynchronization(for: candidate.category) { synchronizer, modelContext, settingsStore in
            try await synchronizer.createRemoteFolderAndSynchronize(
                for: candidate.category,
                replacingRemoteFolderID: candidate.remoteFolderID,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
    }

    /**
     Starts the in-process periodic foreground polling loop when it is not already running.

     - Side Effects: Creates a repeating task that sleeps for `pollIntervalNanoseconds` and then
       asks the service to run a throttled synchronization pass.
     - Failure modes: Multiple start attempts are ignored while one task is already active.
     */
    private func startPeriodicSync() {
        guard periodicTask == nil else {
            return
        }

        periodicTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.sleep(self.pollIntervalNanoseconds)
                guard !Task.isCancelled else {
                    break
                }
                _ = await self.synchronizeIfNeeded(force: false)
            }
        }
    }

    /**
     Returns the enabled remote-sync categories from local settings.

     - Parameter remoteSettingsStore: Local remote-sync settings store.
     - Returns: Enabled categories in Android's declared `allCases` order.
     - Side Effects: Reads category toggle state from `RemoteSyncSettingsStore`.
     - Failure modes: Missing toggle values decode as disabled categories.
     */
    private func enabledCategories(using remoteSettingsStore: RemoteSyncSettingsStore) -> [RemoteSyncCategory] {
        RemoteSyncCategory.allCases.filter { remoteSettingsStore.isSyncEnabled(for: $0) }
    }

    /**
     Runs one user-confirmed adopt-or-replace continuation for a specific sync category.

     - Parameters:
       - category: Logical sync category being resumed after user confirmation.
       - operation: Confirmed remote-sync operation to run once configuration is validated.
     - Returns: `true` when the confirmed operation synchronized successfully.
     - Side Effects:
       - creates fresh `ModelContext` and `SettingsStore` instances for the operation
       - performs remote I/O and may mutate local SwiftData through the supplied operation
       - updates Android's `globalLastSynchronized` key on success
       - invokes the standard success or error callbacks
     - Failure modes:
       - invalid or incomplete remote configuration returns `false`
       - disabled categories return `false`
       - overlapping sync operations return `false`
       - thrown operation failures are reported through `onCategoryError` and return `false`
     */
    private func performInteractiveSynchronization(
        for category: RemoteSyncCategory,
        operation: (
            any RemoteSyncCategorySynchronizing,
            ModelContext,
            SettingsStore
        ) async throws -> RemoteSyncCategorySynchronizationReport
    ) async -> Bool {
        guard !isSynchronizing else {
            return false
        }

        let modelContext = ModelContext(modelContainer)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let remoteSettingsStore = remoteSettingsStoreFactory(settingsStore)

        guard remoteSettingsStore.selectedBackend != .iCloud,
              networkAvailableProvider(),
              remoteSettingsStore.isSyncEnabled(for: category),
              let synchronizer = makeSynchronizer(using: remoteSettingsStore) else {
            return false
        }

        isSynchronizing = true
        defer { isSynchronizing = false }

        do {
            let report = try await operation(synchronizer, modelContext, settingsStore)
            remoteSettingsStore.globalLastSynchronized = nowProvider()
            onCategorySynchronized?(report)
            return true
        } catch {
            onCategoryError?(category, error)
            return false
        }
    }

    /**
     Returns whether Android's periodic interval gate allows another foreground sync pass.

     - Parameters:
       - remoteSettingsStore: Local remote-sync settings store.
       - now: Current wall-clock time in milliseconds.
     - Returns: `true` when the configured sync interval has elapsed since the last successful
       lifecycle-driven pass.
     - Side Effects: Reads `globalLastSynchronized` and `gdrive_sync_interval` from local settings.
     - Failure modes: Missing timestamps or malformed interval values fall back to allowing a pass.
     */
    private func shouldRunPeriodicPass(
        using remoteSettingsStore: RemoteSyncSettingsStore,
        now: Int64
    ) -> Bool {
        guard let lastSynchronized = remoteSettingsStore.globalLastSynchronized else {
            return true
        }
        return now - lastSynchronized >= remoteSettingsStore.remoteSyncIntervalSeconds * 1000
    }

    /**
     Builds the concrete synchronization coordinator from persisted remote-backend settings.

     - Parameter remoteSettingsStore: Local remote-sync settings store.
     - Returns: Concrete synchronization coordinator, or `nil` when configuration is incomplete.
     - Side Effects:
       - reads persisted backend-specific configuration and credentials
       - may generate and persist a stable remote device identifier on first use
     - Failure modes:
       - malformed, incomplete, or unauthenticated configuration returns `nil` instead of throwing
         because lifecycle sync should quietly defer until the user fixes settings or signs in
     */
    private func makeSynchronizer(
        using remoteSettingsStore: RemoteSyncSettingsStore
    ) -> (any RemoteSyncCategorySynchronizing)? {
        do {
            return try synchronizationServiceFactory(remoteSettingsStore)
        } catch {
            return nil
        }
    }

    /**
     Returns whether foreground polling should remain active for the current app configuration.

     - Returns: `true` when a remote backend is selected, at least one category is enabled, and the
       persisted backend settings are complete enough for lifecycle sync to build a synchronizer.
     - Side Effects: Reads backend selection, category toggles, and backend-specific auth/config state.
     - Failure modes: Incomplete or malformed configuration returns `false`.
     */
    private func isLifecycleSyncConfigured() -> Bool {
        let modelContext = ModelContext(modelContainer)
        let remoteSettingsStore = remoteSettingsStoreFactory(SettingsStore(modelContext: modelContext))
        guard remoteSettingsStore.selectedBackend != .iCloud,
              !enabledCategories(using: remoteSettingsStore).isEmpty else {
            return false
        }
        return makeSynchronizer(using: remoteSettingsStore) != nil
    }
}
