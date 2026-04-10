// AndBibleApp.swift — Main app entry point

import SwiftUI
import SwiftData
import Darwin
import BibleCore
import BibleUI
import SwordKit
#if os(iOS)
import UIKit
import Network
#endif

/**
 AndBible iOS — Powerful offline Bible study app.

 Universal SwiftUI app for iPhone, iPad, and Mac.
 */
/**
 Tracks best-effort network availability for lifecycle-driven remote sync.

 Android suppresses remote sync when the network is unavailable. iOS uses `NWPathMonitor` to
 mirror that guard so lifecycle-triggered NextCloud or Google Drive sync does not immediately fail
 and surface avoidable transport errors while offline.

 Side effects:
 - starts `NWPathMonitor` updates on a dedicated background queue at initialization time
 - keeps the latest path status in memory for synchronous reads from the app scene

 Failure modes:
 - when the monitor has not produced a path yet, `isNetworkAvailable` falls back to `false`
 - this monitor is advisory only; higher-level sync services still handle transport failures
 */
private final class RemoteSyncNetworkMonitor {
    #if os(iOS)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.andbible.remote-sync-network")
    private let lock = NSLock()
    private var currentStatus: NWPath.Status
    #endif

    /**
     Creates and starts the best-effort network monitor.
     *
     * - Side effects:
     *   - starts `NWPathMonitor` on a dedicated queue on iOS
     * - Failure modes: This initializer cannot fail.
     */
    init() {
        #if os(iOS)
        currentStatus = monitor.currentPath.status
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }
            self.lock.lock()
            self.currentStatus = path.status
            self.lock.unlock()
        }
        monitor.start(queue: queue)
        #endif
    }

    deinit {
        #if os(iOS)
        monitor.cancel()
        #endif
    }

    /**
     Returns whether the latest observed network path is currently satisfied.
     *
     * - Returns: `true` when a usable network path is currently available.
     * - Side effects: Reads the latest cached path status under a lock.
     * - Failure modes:
     *   - non-iOS builds always return `true`
     *   - iOS returns `false` until the first satisfied path is observed
     */
    var isNetworkAvailable: Bool {
        #if os(iOS)
        lock.lock()
        defer { lock.unlock() }
        return currentStatus == .satisfied
        #else
        return true
        #endif
    }
}

/**
 Describes the destructive confirmation step for a lifecycle-time remote-sync decision.

 Android shows two dialogs when an existing remote folder is found during cloud sync bootstrap: a
 first choice between adopting cloud content or replacing it, followed by a confirmation explaining
 which side will be reset. The app shell uses this enum to preserve that flow when lifecycle-driven
 NextCloud sync encounters the same ambiguity outside the settings screen.
 */
private enum PendingRemoteSyncConfirmation: Identifiable, Equatable {
    /// Confirm replacing local content with the discovered remote folder.
    case resetLocal(RemoteSyncBootstrapCandidate)

    /// Confirm replacing the discovered remote folder with local content.
    case resetCloud(RemoteSyncBootstrapCandidate)

    /**
     Stable alert identity derived from the category and confirmation branch.
     *
     * - Returns: Stable per-category alert identifier.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    var id: String {
        switch self {
        case .resetLocal(let candidate):
            return "lifecycle-reset-local-\(candidate.category.rawValue)"
        case .resetCloud(let candidate):
            return "lifecycle-reset-cloud-\(candidate.category.rawValue)"
        }
    }

    /**
     Sync category affected by the destructive lifecycle confirmation.
     *
     * - Returns: Logical sync category referenced by the confirmation.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    var category: RemoteSyncCategory {
        switch self {
        case .resetLocal(let candidate), .resetCloud(let candidate):
            return candidate.category
        }
    }
}

@main
struct AndBibleApp: App {
    /// SwiftData model container for all persisted entities.
    let modelContainer: ModelContainer

    /// Core services shared across the app.
    @State private var windowManager: WindowManager
    private let speakService = SpeakService()
    @State private var syncService: SyncService
    @State private var searchIndexService = SearchIndexService()
    @State private var googleDriveAuthService: GoogleDriveAuthService
    @State private var remoteSyncLifecycleService: RemoteSyncLifecycleService
    @State private var pendingRemoteAdoption: RemoteSyncBootstrapCandidate?
    @State private var queuedRemoteAdoptions: [RemoteSyncBootstrapCandidate] = []
    @State private var pendingRemoteConfirmation: PendingRemoteSyncConfirmation?
    @State private var remoteSyncErrorMessage: String?
    private let remoteSyncNetworkMonitor: RemoteSyncNetworkMonitor
    #if os(iOS)
    private let remoteSyncBackgroundRefreshCoordinator: RemoteSyncBackgroundRefreshCoordinator
    #endif

    @Environment(\.scenePhase) private var scenePhase

    /// Discrete mode persists across launches — controls icon switching.
    @AppStorage(AppPreferenceKey.discreteMode.rawValue) private var isDiscreteMode = false
    /// When enabled, calculator gate appears on every app launch/resume.
    @AppStorage(AppPreferenceKey.showCalculator.rawValue) private var showCalculator = false
    /// Temporary unlock for the current session — does NOT change the persisted setting.
    @State private var isUnlocked = false

    /**
     UserDefaults key for the iCloud sync toggle.
     Read from UserDefaults (not SwiftData) because we need it before the container is created.
     */
    static let iCloudSyncEnabledKey = "icloud_sync_enabled"

    init() {
        let networkMonitor = RemoteSyncNetworkMonitor()
        self.remoteSyncNetworkMonitor = networkMonitor

        // Repair any stale migration state before creating the ModelContainer.
        DataMigration.migrateIfNeeded()

        // Read iCloud sync preference from UserDefaults (before container creation)
        let iCloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudSyncEnabledKey)

        // -- User data models: keep config name "AndBible" so existing store file is reused.
        // When iCloud sync is enabled, these models sync via CloudKit. --
        let cloudModels: [any PersistentModel.Type] = [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
        ]

        // -- Device-local models: never sync, separate store. --
        let localModels: [any PersistentModel.Type] = [
            Repository.self,
            Setting.self,
        ]

        let allModels = cloudModels + localModels
        let schema = Schema(allModels)

        // Keep the original config name "AndBible" so SwiftData reuses the existing
        // "AndBible.store" file. Changing the name would break PersistentIdentifiers.
        let cloudConfig = ModelConfiguration(
            "AndBible",
            schema: Schema(cloudModels),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: iCloudEnabled ? .private("iCloud.org.andbible.ios") : .none
        )

        let localConfig = ModelConfiguration(
            "LocalStore",
            schema: Schema(localModels),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        // Set up SWORD module directory before creating any SwordManager
        SwordSetup.ensureModulesReady()

        // Initialize SyncService with current toggle state
        let sync = SyncService()
        sync.setInitialState(enabled: iCloudEnabled)
        self._syncService = State(initialValue: sync)

        do {
            let container = try ModelContainer(for: schema, configurations: [cloudConfig, localConfig])
            self.modelContainer = container

            // Initialize services that need ModelContext
            let context = ModelContext(container)
            let workspaceStore = WorkspaceStore(modelContext: context)
            let windowMgr = WindowManager(workspaceStore: workspaceStore)
            self._windowManager = State(initialValue: windowMgr)
            let googleDriveAuthService = GoogleDriveAuthService()
            self._googleDriveAuthService = State(initialValue: googleDriveAuthService)

            let remoteSyncLifecycleService = RemoteSyncLifecycleService(
                modelContainer: container,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios",
                synchronizationServiceFactory: { remoteSettingsStore in
                    try RemoteSyncSynchronizationServiceFactory(
                        bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios",
                        googleDriveAccessTokenProvider: { [googleDriveAuthService] in
                            try await googleDriveAuthService.accessToken()
                        }
                    )
                    .makeSynchronizationService(using: remoteSettingsStore)
                },
                networkAvailableProvider: { [networkMonitor] in
                    networkMonitor.isNetworkAvailable
                }
            )
            remoteSyncLifecycleService.onCategorySynchronized = { report in
                guard report.category == .workspaces else {
                    return
                }
                Self.restoreActiveWorkspace(windowManager: windowMgr, modelContainer: container)
            }
            self._remoteSyncLifecycleService = State(initialValue: remoteSyncLifecycleService)
            #if os(iOS)
            let remoteSyncBackgroundRefreshCoordinator = RemoteSyncBackgroundRefreshCoordinator(
                modelContainer: container,
                synchronizeIfNeeded: { force in
                    await remoteSyncLifecycleService.synchronizeIfNeeded(force: force)
                }
            )
            remoteSyncBackgroundRefreshCoordinator.register()
            self.remoteSyncBackgroundRefreshCoordinator = remoteSyncBackgroundRefreshCoordinator
            #endif

            // Ensure at least one workspace exists
            Self.restoreActiveWorkspace(
                windowManager: windowMgr,
                modelContainer: container,
                workspaceStore: workspaceStore,
                settingsStore: SettingsStore(modelContext: context)
            )

            // Seed default labels on first launch (matches Android)
            let bookmarkStore = BookmarkStore(modelContext: context)
            let bookmarkService = BookmarkService(store: bookmarkStore)
            bookmarkService.prepareDefaultLabels()
            // Ensure system labels use deterministic UUIDs for CloudKit dedup
            bookmarkService.ensureSystemLabels()

            // Start monitoring iCloud account status
            sync.startMonitoring(container: container)

            if ProcessInfo.processInfo.environment["UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH"] == "1" {
                DispatchQueue.main.async {
                    Darwin.exit(EXIT_SUCCESS)
                }
            }
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showCalculator && !isUnlocked {
                    CalculatorView {
                        withAnimation {
                            isUnlocked = true
                        }
                    }
                } else {
                    ContentView()
                        .environment(windowManager)
                        .environment(syncService)
                        .environment(searchIndexService)
                        .environment(googleDriveAuthService)
                }
            }
            .task {
                configureRemoteSyncLifecycleCallbacks()
                #if os(iOS)
                remoteSyncBackgroundRefreshCoordinator.scheduleNextRefreshIfNeeded()
                #endif
                await googleDriveAuthService.restorePreviousSignInIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    // Reconcile icon state when app becomes active
                    // (setAlternateIconName fails if called before app is fully active)
                    updateAppIcon(discrete: isDiscreteMode)
                    Task {
                        await remoteSyncLifecycleService.sceneDidBecomeActive()
                        #if os(iOS)
                        remoteSyncBackgroundRefreshCoordinator.scheduleNextRefreshIfNeeded()
                        #endif
                    }
                } else if newPhase == .background {
                    #if os(iOS)
                    remoteSyncBackgroundRefreshCoordinator.scheduleNextRefreshIfNeeded()
                    #endif
                    runRemoteSyncBackgroundPass()
                } else if newPhase == .inactive {
                    remoteSyncLifecycleService.stopPeriodicSync()
                }
            }
            .onChange(of: isDiscreteMode) { _, newValue in
                updateAppIcon(discrete: newValue)
            }
            .onChange(of: showCalculator) { _, newValue in
                // When user turns off calculator gate, clear unlock state
                if !newValue {
                    isUnlocked = false
                }
            }
            .onOpenURL { url in
                _ = googleDriveAuthService.handle(url: url)
            }
            .alert(
                String(localized: "cloud_sync_title"),
                isPresented: Binding(
                    get: { pendingRemoteAdoption != nil },
                    set: { newValue in
                        if !newValue {
                            pendingRemoteAdoption = nil
                            showNextPendingRemoteAdoptionIfNeeded()
                        }
                    }
                ),
                presenting: pendingRemoteAdoption
            ) { candidate in
                Button(String(localized: "cloud_fetch_and_restore_initial")) {
                    pendingRemoteConfirmation = .resetLocal(candidate)
                    pendingRemoteAdoption = nil
                }
                Button(String(localized: "cloud_create_new")) {
                    pendingRemoteConfirmation = .resetCloud(candidate)
                    pendingRemoteAdoption = nil
                }
                Button(String(localized: "cloud_disable_sync"), role: .cancel) {
                    disableRemoteSync(for: candidate.category)
                    pendingRemoteAdoption = nil
                    showNextPendingRemoteAdoptionIfNeeded()
                }
            } message: { candidate in
                Text(
                    String(
                        format: String(localized: "overrideBackup"),
                        remoteCategoryContentDescription(for: candidate.category)
                    )
                )
            }
            .alert(
                String(localized: "are_you_sure"),
                isPresented: Binding(
                    get: { pendingRemoteConfirmation != nil },
                    set: { newValue in
                        if !newValue {
                            pendingRemoteConfirmation = nil
                            showNextPendingRemoteAdoptionIfNeeded()
                        }
                    }
                ),
                presenting: pendingRemoteConfirmation
            ) { confirmation in
                Button(String(localized: "ok"), role: .destructive) {
                    let capturedConfirmation = confirmation
                    pendingRemoteConfirmation = nil
                    Task {
                        await continueRemoteSynchronization(after: capturedConfirmation)
                    }
                }
                Button(String(localized: "cancel"), role: .cancel) {
                    disableRemoteSync(for: confirmation.category)
                    pendingRemoteConfirmation = nil
                    showNextPendingRemoteAdoptionIfNeeded()
                }
            } message: { confirmation in
                Text(remoteConfirmationMessage(for: confirmation))
            }
            .alert(
                String(localized: "cloud_sync_title"),
                isPresented: Binding(
                    get: { remoteSyncErrorMessage != nil },
                    set: { newValue in
                        if !newValue {
                            remoteSyncErrorMessage = nil
                        }
                    }
                )
            ) {
                Button(String(localized: "ok")) {
                    remoteSyncErrorMessage = nil
                }
            } message: {
                Text(remoteSyncErrorMessage ?? String(localized: "sync_error"))
            }
        }
        .modelContainer(modelContainer)
    }

    private func updateAppIcon(discrete: Bool, retryCount: Int = 0) {
        #if os(iOS)
        let iconName: String? = discrete ? "CalculatorIcon" : nil
        let currentIcon = UIApplication.shared.alternateIconName
        guard UIApplication.shared.supportsAlternateIcons,
              currentIcon != iconName else { return }
        UIApplication.shared.setAlternateIconName(iconName) { error in
            if error != nil, retryCount < 3 {
                // Retry with increasing delay (startup timing can cause transient failures)
                let delay = Double(retryCount + 1) * 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.updateAppIcon(discrete: discrete, retryCount: retryCount + 1)
                }
            }
        }
        #endif
    }

    /**
     Runs one best-effort lifecycle-driven remote-sync pass while the scene is backgrounding.
     *
     * - Side effects:
       - begins a finite iOS background task so remote sync has time to finish after the scene
         backgrounds
       - delegates the actual sync work to `RemoteSyncLifecycleService`
     * - Failure modes:
       - if iOS terminates the background task early, the pass is simply cancelled on the next launch/foreground cycle
     */
    private func runRemoteSyncBackgroundPass() {
        #if os(iOS)
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "AndBibleRemoteSync") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        Task {
            await remoteSyncLifecycleService.sceneDidEnterBackground()
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
        #else
        Task {
            await remoteSyncLifecycleService.sceneDidEnterBackground()
        }
        #endif
    }

    /**
     Wires lifecycle-sync callbacks into app-shell prompt and error state.
     *
     * - Side effects:
       - installs adopt/create decision handling callbacks on `RemoteSyncLifecycleService`
       - routes synchronization errors into the app-level alert state
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func configureRemoteSyncLifecycleCallbacks() {
        remoteSyncLifecycleService.onInteractionRequired = { _, outcome in
            guard case .requiresRemoteAdoption(let candidate) = outcome else {
                return
            }
            enqueueRemoteAdoption(candidate)
        }
        remoteSyncLifecycleService.onCategoryError = { category, error in
            handleRemoteSyncError(error, for: category)
        }
    }

    /**
     Adds a lifecycle-time adopt/create decision to the app-shell queue.
     *
     * - Parameter candidate: Remote folder candidate that needs user input.
     * - Side effects:
       - stores the candidate in either the active slot or the FIFO queue
       - deduplicates candidates by sync category so periodic sync cannot stack identical prompts
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func enqueueRemoteAdoption(_ candidate: RemoteSyncBootstrapCandidate) {
        if pendingRemoteAdoption?.category == candidate.category ||
            pendingRemoteConfirmation?.category == candidate.category ||
            queuedRemoteAdoptions.contains(where: { $0.category == candidate.category }) {
            return
        }

        if pendingRemoteAdoption == nil && pendingRemoteConfirmation == nil {
            pendingRemoteAdoption = candidate
        } else {
            queuedRemoteAdoptions.append(candidate)
        }
    }

    /**
     Promotes the next queued lifecycle decision into the active alert slot when possible.
     *
     * - Side effects: Mutates `pendingRemoteAdoption` and `queuedRemoteAdoptions`.
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func showNextPendingRemoteAdoptionIfNeeded() {
        guard pendingRemoteAdoption == nil,
              pendingRemoteConfirmation == nil,
              !queuedRemoteAdoptions.isEmpty else {
            return
        }

        pendingRemoteAdoption = queuedRemoteAdoptions.removeFirst()
    }

    /**
     Continues lifecycle-driven synchronization after the user confirmed adopt-or-replace.
     *
     * - Parameter confirmation: Destructive action the user confirmed.
     * - Side effects:
       - resumes lifecycle-driven remote sync through `RemoteSyncLifecycleService`
       - may update `remoteSyncErrorMessage` when the confirmed sync action fails silently
       - advances the prompt queue after the confirmed action completes
     * - Failure modes:
       - failed adopt/create operations leave category enablement unchanged, matching Android's retry behavior
     */
    @MainActor
    private func continueRemoteSynchronization(after confirmation: PendingRemoteSyncConfirmation) async {
        let didSynchronize: Bool

        switch confirmation {
        case .resetLocal(let candidate):
            didSynchronize = await remoteSyncLifecycleService.adoptRemoteFolderAndSynchronize(candidate)
        case .resetCloud(let candidate):
            didSynchronize = await remoteSyncLifecycleService.replaceRemoteFolderAndSynchronize(candidate)
        }

        if !didSynchronize && remoteSyncErrorMessage == nil {
            remoteSyncErrorMessage = String(localized: "sync_error")
        }

        showNextPendingRemoteAdoptionIfNeeded()
    }

    /**
     Disables one remote-sync category immediately from app-shell lifecycle prompts.
     *
     * - Parameter category: Logical sync category to disable.
     * - Side effects:
       - writes the Android `gdrive_*` toggle as `false`
       - removes any queued prompt for the same category
     * - Failure modes:
       - `SettingsStore` write failures are swallowed by `RemoteSyncSettingsStore`
     */
    @MainActor
    private func disableRemoteSync(for category: RemoteSyncCategory) {
        let context = ModelContext(modelContainer)
        let settingsStore = SettingsStore(modelContext: context)
        let remoteSettingsStore = RemoteSyncSettingsStore(settingsStore: settingsStore)
        remoteSettingsStore.setSyncEnabled(false, for: category)
        queuedRemoteAdoptions.removeAll { $0.category == category }
    }

    /**
     Maps lifecycle-driven remote-sync errors into user-visible app-shell alert text.
     *
     * - Parameters:
       - error: Failure emitted by the lifecycle synchronization service.
       - category: Logical sync category that failed.
     * - Side effects:
       - may disable the category for incompatible remote schema failures
       - updates the app-level error-alert message
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func handleRemoteSyncError(_ error: Error, for category: RemoteSyncCategory) {
        switch error {
        case WebDAVClientError.invalidURL:
            remoteSyncErrorMessage = String(localized: "invalid_url_message")
        case RemoteSyncPatchDiscoveryError.incompatiblePatchVersion:
            disableRemoteSync(for: category)
            remoteSyncErrorMessage = [
                String(localized: "sync_cant_fetch"),
                String(
                    format: String(localized: "sync_disabling"),
                    remoteCategoryContentDescription(for: category)
                ),
                String(localized: "sync_update_app"),
            ]
            .joined(separator: " ")
        default:
            let localizedMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteSyncErrorMessage = localizedMessage.isEmpty ? String(localized: "sync_error") : localizedMessage
        }
    }

    /**
     Returns Android's category description string for the supplied sync category.
     *
     * - Parameter category: Logical sync category to describe.
     * - Returns: Localized Android-aligned category description.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func remoteCategoryContentDescription(for category: RemoteSyncCategory) -> String {
        switch category {
        case .bookmarks:
            return String(localized: "bookmarks_contents")
        case .workspaces:
            return String(localized: "workspaces_contents")
        case .readingPlans:
            return String(localized: "reading_plans_content")
        }
    }

    /**
     Returns the localized destructive-confirmation message for one lifecycle adopt-or-replace choice.
     *
     * - Parameter confirmation: Pending destructive confirmation branch.
     * - Returns: Localized confirmation body text.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func remoteConfirmationMessage(for confirmation: PendingRemoteSyncConfirmation) -> String {
        switch confirmation {
        case .resetLocal(let candidate):
            return String(
                format: String(localized: "are_you_sure_reset_local"),
                remoteCategoryContentDescription(for: candidate.category)
            )
        case .resetCloud(let candidate):
            return String(
                format: String(localized: "are_you_sure_reset_cloud"),
                remoteCategoryContentDescription(for: candidate.category)
            )
        }
    }

    /**
     Reconciles `WindowManager` against the currently persisted active workspace selection.
     *
     * - Parameters:
       - windowManager: Live window manager driving the visible workspace UI.
       - modelContainer: Model container used to create fallback store/context instances.
       - workspaceStore: Optional prebuilt workspace store for the current context.
       - settingsStore: Optional prebuilt settings store for the current context.
     * - Side effects:
       - may switch the active workspace shown in the UI
       - may create a default workspace when no persisted workspace exists
       - may repair `activeWorkspaceId` in `SettingsStore`
     * - Failure modes:
       - if persisted workspace identifiers point at missing rows, the first available workspace becomes active instead
     */
    private static func restoreActiveWorkspace(
        windowManager: WindowManager,
        modelContainer: ModelContainer,
        workspaceStore: WorkspaceStore? = nil,
        settingsStore: SettingsStore? = nil
    ) {
        let context = ModelContext(modelContainer)
        let resolvedWorkspaceStore = workspaceStore ?? WorkspaceStore(modelContext: context)
        let resolvedSettingsStore = settingsStore ?? SettingsStore(modelContext: context)

        if let activeID = resolvedSettingsStore.activeWorkspaceId,
           let workspace = resolvedWorkspaceStore.workspace(id: activeID) {
            windowManager.setActiveWorkspace(workspace)
            return
        }

        let workspaces = resolvedWorkspaceStore.workspaces()
        if let first = workspaces.first {
            windowManager.setActiveWorkspace(first)
            resolvedSettingsStore.activeWorkspaceId = first.id
            return
        }

        let newWorkspace = resolvedWorkspaceStore.createWorkspace(name: "Default")
        windowManager.setActiveWorkspace(newWorkspace)
        resolvedSettingsStore.activeWorkspaceId = newWorkspace.id
    }
}
