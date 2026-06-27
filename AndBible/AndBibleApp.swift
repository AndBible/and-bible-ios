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
 mirror that guard so lifecycle-triggered NextCloud/WebDAV sync does not immediately fail and
 surface avoidable transport errors while offline.

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
    @State private var remoteSyncLifecycleService: RemoteSyncLifecycleService
    @State private var pendingRemoteAdoption: RemoteSyncBootstrapCandidate?
    @State private var queuedRemoteAdoptions: [RemoteSyncBootstrapCandidate] = []
    @State private var pendingRemoteConfirmation: PendingRemoteSyncConfirmation?
    @State private var remoteSyncErrorMessage: String?
    /// External document waiting for Android-style install confirmation.
    @State private var pendingExternalDocumentImport: ExternalDocumentImportRequest?
    /// Additional external documents delivered while another import prompt/result is active.
    @State private var queuedExternalDocumentImports: [ExternalDocumentImportRequest] = []
    /// Whether an external document import task is currently mutating storage.
    @State private var isImportingExternalDocument = false
    /// Pending app-level feedback for a document opened from Files, Mail, or another app.
    @State private var externalDocumentImportMessage: String?
    /// Pending Android-style transient install-success toast for a confirmed external document.
    @State private var externalDocumentImportToastMessage: String?
    /// Scheduled dismissal for the current external document install-success toast.
    @State private var externalDocumentImportToastWorkItem: DispatchWorkItem?
    private let remoteSyncNetworkMonitor: RemoteSyncNetworkMonitor
    #if os(iOS)
    private let remoteSyncBackgroundRefreshCoordinator: RemoteSyncBackgroundRefreshCoordinator
    @UIApplicationDelegateAdaptor(AndBibleApplicationDelegate.self) private var appDelegate
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

    /**
     User-visible recovery message shown when CloudKit-backed SwiftData startup fails.
     *
     * The app has already recovered by opening the same store locally and clearing the iCloud
     * bootstrap toggle before this message is presented. Keep this copy generic because failures
     * can come from iCloud availability, entitlement, or model-compatibility validation.
     */
    private static var iCloudStartupRecoveryMessage: String {
        String(
            localized: "icloud_startup_recovery_message",
            defaultValue: "iCloud sync could not be started, so sync was turned off and AndBible opened your local data."
        )
    }

    init() {
        let networkMonitor = RemoteSyncNetworkMonitor()
        self.remoteSyncNetworkMonitor = networkMonitor

        // Repair any stale migration state before creating the ModelContainer.
        DataMigration.migrateIfNeeded()

        // Read iCloud sync preference from UserDefaults (before container creation)
        let requestedICloudEnabled = UserDefaults.standard.bool(forKey: Self.iCloudSyncEnabledKey)

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
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
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
        let localConfig = ModelConfiguration(
            "LocalStore",
            schema: Schema(localModels),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        // Set up SWORD module directory before creating any SwordManager
        SwordSetup.ensureModulesReady()

        // Initialize SyncService after container startup resolves the effective CloudKit mode.
        let sync = SyncService()

        do {
            let startupResult = try ICloudModelContainerStartupRecovery.loadContainer(
                iCloudEnabled: requestedICloudEnabled,
                syncEnabledKey: Self.iCloudSyncEnabledKey,
                loadCloudKitContainer: {
                    let cloudConfig = ModelConfiguration(
                        "AndBible",
                        schema: Schema(cloudModels),
                        isStoredInMemoryOnly: false,
                        cloudKitDatabase: .private("iCloud.org.andbible.ios")
                    )
                    return try ModelContainer(for: schema, configurations: [cloudConfig, localConfig])
                },
                loadLocalContainer: {
                    let cloudConfig = ModelConfiguration(
                        "AndBible",
                        schema: Schema(cloudModels),
                        isStoredInMemoryOnly: false,
                        cloudKitDatabase: .none
                    )
                    return try ModelContainer(for: schema, configurations: [cloudConfig, localConfig])
                }
            )
            let container = startupResult.container
            sync.setInitialState(enabled: startupResult.effectiveICloudEnabled)
            self._syncService = State(initialValue: sync)
            if startupResult.didRecoverFromCloudKitFailure {
                self._remoteSyncErrorMessage = State(initialValue: Self.iCloudStartupRecoveryMessage)
            }
            self.modelContainer = container

            // Initialize services that need ModelContext
            let context = ModelContext(container)
            let workspaceStore = WorkspaceStore(modelContext: context)
            let windowMgr = WindowManager(workspaceStore: workspaceStore)
            self._windowManager = State(initialValue: windowMgr)

            let remoteSyncLifecycleService = RemoteSyncLifecycleService(
                modelContainer: container,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios",
                synchronizationServiceFactory: { remoteSettingsStore in
                    try RemoteSyncSynchronizationServiceFactory(
                        bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios"
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
                // Give XCTest time to finish launch bookkeeping before the bootstrap process exits.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
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
                }
            }
            .task {
                configureRemoteSyncLifecycleCallbacks()
                #if os(iOS)
                remoteSyncBackgroundRefreshCoordinator.scheduleNextRefreshIfNeeded()
                #endif
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
                handleExternalDocumentURL(url)
            }
            .androidToastFeedback(externalDocumentImportToastMessage, bottomPadding: 96)
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
            .alert(
                String(localized: "import_from_file", defaultValue: "Import from File"),
                isPresented: Binding(
                    get: { pendingExternalDocumentImport != nil },
                    set: { newValue in
                        if !newValue {
                            pendingExternalDocumentImport = nil
                            showNextPendingExternalDocumentImportIfNeeded()
                        }
                    }
                ),
                presenting: pendingExternalDocumentImport
            ) { request in
                Button(String(localized: "ok")) {
                    pendingExternalDocumentImport = nil
                    performExternalDocumentImport(request)
                }
                Button(String(localized: "cancel"), role: .cancel) {
                    // The dismissal binding owns cancel queue advancement.
                }
            } message: { request in
                Text(externalDocumentImportConfirmationMessage(for: request))
            }
            .alert(
                String(localized: "import_from_file", defaultValue: "Import from File"),
                isPresented: Binding(
                    get: { externalDocumentImportMessage != nil },
                    set: { newValue in
                        if !newValue {
                            externalDocumentImportMessage = nil
                            showNextPendingExternalDocumentImportIfNeeded()
                        }
                    }
                )
            ) {
                Button(String(localized: "ok")) {
                    externalDocumentImportMessage = nil
                    showNextPendingExternalDocumentImportIfNeeded()
                }
            } message: {
                Text(externalDocumentImportMessage ?? "")
            }
        }
        .modelContainer(modelContainer)
    }

    /**
     Handles files opened into AndBible from iOS document interaction surfaces.

     The app advertises ZIP, EPUB, and TTF document types to mirror Android's implemented
     `InstallZip` entry points. External opens match Android `ACTION_VIEW`: the user confirms the
     install before storage is mutated, while the confirmed request still flows through the same
     shared service used by Backup & Restore.

     - Parameter url: External file URL delivered by SwiftUI for the active scene.
     - Side effects:
       - ignores non-file URLs delivered by unrelated URL-opening mechanisms
       - queues the request when another external import prompt or result is active
       - presents Android-style confirmation before installation
       - later performs module/EPUB/TTF installation in a user-initiated task
     - Failure modes: Unsupported files and installer failures are converted to localized feedback
       by `ExternalDocumentImportService`.
     */
    @MainActor
    private func handleExternalDocumentURL(_ url: URL) {
        guard url.isFileURL else {
            return
        }
        let request = ExternalDocumentImportRequest(url: url)
        if pendingExternalDocumentImport == nil,
           externalDocumentImportMessage == nil,
           externalDocumentImportToastMessage == nil,
           !isImportingExternalDocument {
            pendingExternalDocumentImport = request
        } else {
            queuedExternalDocumentImports.append(request)
        }
    }

    /**
     Performs a confirmed external document import.

     - Parameter request: External document request previously confirmed by the user.
     - Side effects:
       - marks the app-level import as active
       - runs the shared import service off the main actor
       - publishes Android install successes as transient toast feedback
       - publishes unsupported-format and failure feedback to SwiftUI alert state
     - Failure modes: Service-level failures are surfaced as result feedback instead of thrown.
     */
    @MainActor
    private func performExternalDocumentImport(_ request: ExternalDocumentImportRequest) {
        isImportingExternalDocument = true
        externalDocumentImportMessage = nil
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                ExternalDocumentImportService().importDocument(request)
            }.value
            isImportingExternalDocument = false
            if result.usesAndroidInstallToastFeedback {
                showExternalDocumentImportToast(result.feedbackMessage)
            } else {
                externalDocumentImportMessage = result.feedbackMessage
            }
        }
    }

    /**
     Presents Android-style install-success feedback for app-opened documents.

     Android `InstallZip` reports successful document installs with a short `ToastEvent`, not a
     blocking dialog. This helper owns the app-level dismissal timing and resumes queued external
     import prompts only after the toast clears so prompts do not stack over transient feedback.

     - Parameter message: Localized toast text to display.
     - Side effects:
       - cancels any pending external-import toast dismissal
       - mutates app-level toast state
       - schedules automatic dismissal and queued-import advancement
     - Failure modes: none; newer toast requests replace earlier requests.
     */
    @MainActor
    private func showExternalDocumentImportToast(_ message: String) {
        externalDocumentImportToastWorkItem?.cancel()
        withAnimation { externalDocumentImportToastMessage = message }
        let work = DispatchWorkItem {
            withAnimation { externalDocumentImportToastMessage = nil }
            externalDocumentImportToastWorkItem = nil
            showNextPendingExternalDocumentImportIfNeeded()
        }
        externalDocumentImportToastWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AndroidToastFeedback.shortDuration,
            execute: work
        )
    }

    /**
     Presents the next queued external import when no prompt, task, result alert, or toast is active.

     - Side effects: Mutates the external import queue and pending prompt state.
     - Failure modes: none.
     */
    @MainActor
    private func showNextPendingExternalDocumentImportIfNeeded() {
        guard pendingExternalDocumentImport == nil,
              externalDocumentImportMessage == nil,
              externalDocumentImportToastMessage == nil,
              !isImportingExternalDocument,
              !queuedExternalDocumentImports.isEmpty else {
            return
        }
        pendingExternalDocumentImport = queuedExternalDocumentImports.removeFirst()
    }

    /**
     Builds Android's external-open install confirmation message.

     - Parameter request: Pending external document request.
     - Returns: Localized confirmation text naming the selected file.
     - Side effects: none.
     */
    private func externalDocumentImportConfirmationMessage(for request: ExternalDocumentImportRequest) -> String {
        let displayName = request.displayFileName ?? "?"
        return String(
            format: String(
                localized: "install_do_you_want",
                defaultValue: "Do you want to install %@?"
            ),
            displayName
        )
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
        RemoteSyncCategoryLocalization.text(for: category).contents.localized
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
