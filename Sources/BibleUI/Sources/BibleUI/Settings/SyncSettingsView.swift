// SyncSettingsView.swift — Sync backend settings

import SwiftUI
import SwiftData
import BibleCore

/**
 Configures the active sync backend and surfaces backend-specific settings.

 The screen now acts as the entry point for the existing CloudKit implementation plus the Android-
 aligned NextCloud/WebDAV and Google Drive backends. It preserves the current iCloud toggle/status
 flow while allowing the remote backends to edit credentials, restore cached auth state, and
 perform category-scoped synchronization without changing the active CloudKit runtime mid-session.

 Data dependencies:
 - `SyncService` provides the effective iCloud sync mode, account description, runtime state, and
   last known sync timestamp
 - SwiftData's environment `modelContext` provides access to `SettingsStore` through
   `RemoteSyncSettingsStore`
 - `GoogleDriveAuthService` provides Google OAuth session state, scope readiness, and access tokens
 - localized strings provide backend labels, field titles, status text, and warnings

 Side effects:
 - changing the selected backend persists `sync_adapter` through `RemoteSyncSettingsStore`
 - editing WebDAV credentials updates local state and can be persisted to SwiftData plus Keychain
 - testing a NextCloud/WebDAV connection builds a transient `WebDAVClient` and performs a network
   request against the configured server
 - switching to Google Drive can trigger best-effort cached-session restoration through
   `GoogleDriveAuthService`
 - starting Google Drive sync can present interactive Google Sign-In or scope-consent UI
 - toggling iCloud sync calls back into `SyncService` and can persist a restart-required sync mode
 - disabling iCloud sync first presents a confirmation dialog before mutating the service state
 */
public struct SyncSettingsView: View {
    /// Shared CloudKit sync service injected from the app environment.
    @Environment(SyncService.self) private var syncService

    /// Shared Google Drive auth/session service injected from the app environment.
    @Environment(GoogleDriveAuthService.self) private var googleDriveAuthService

    /// SwiftData context used to materialize the local settings store.
    @Environment(\.modelContext) private var modelContext

    /// Whether the destructive disable-sync confirmation dialog is presented.
    @State private var showDisableConfirmation = false

    /// Whether the restart-required informational alert is presented.
    @State private var showRestartAlert = false

    /// Currently selected sync backend shown in the backend picker.
    @State private var selectedBackend: RemoteSyncBackend = .iCloud

    /// User-entered or persisted NextCloud/WebDAV server root URL.
    @State private var serverURL = ""

    /// User-entered or persisted NextCloud/WebDAV username.
    @State private var username = ""

    /// User-entered or persisted NextCloud/WebDAV password.
    @State private var password = ""

    /// User-entered or persisted optional sync folder path.
    @State private var folderPath = ""

    /// Guards one-time loading of persisted backend settings into local view state.
    @State private var hasLoadedSettings = false

    /// Whether a NextCloud/WebDAV connection test is currently in flight.
    @State private var isTestingConnection = false

    /// Latest result from the manual NextCloud/WebDAV connection test, if any.
    @State private var remoteConnectionStatus: RemoteConnectionStatus?

    /// Persisted enabled state for each Android-style remote sync category.
    @State private var remoteCategoryEnabled: [RemoteSyncCategory: Bool] = [:]

    /// Transient in-flight or failed synchronization state for each remote sync category.
    @State private var remoteCategoryStatuses: [RemoteSyncCategory: RemoteSyncCategoryStatus] = [:]

    /// Pending adopt-versus-create prompt for a discovered remote folder.
    @State private var pendingRemoteAdoption: RemoteSyncBootstrapCandidate?

    /// Pending destructive confirmation after the user chose adopt or replace.
    @State private var pendingRemoteConfirmation: PendingRemoteConfirmation?

    /// Whether the Android-aligned Google Drive sign-out/reset confirmation is presented.
    @State private var showGoogleDriveResetConfirmation = false

    /// Global remote-sync error message shown in an alert after a category sync failure.
    @State private var remoteSyncErrorMessage: String?

    /**
     Represents the last manual WebDAV connection-test result shown in the status section.

     The enum is view-local because it only drives transient UI feedback and is never persisted.
     */
    private enum RemoteConnectionStatus: Equatable {
        /// The most recent connection test completed successfully.
        case success

        /// The most recent connection test failed with a human-readable message.
        case failure(String)
    }

    /**
     Represents the transient synchronization state of one Android-style remote sync category.

     The persisted enablement toggle lives in `RemoteSyncSettingsStore`. This enum only captures
     ephemeral UI state that should not survive view recreation, such as an in-flight bootstrap or
     the latest failure message produced while the user is interacting with settings.
     */
    private enum RemoteSyncCategoryStatus: Equatable {
        /// No transient work or error is active for the category.
        case idle

        /// Synchronization is currently in flight for the category.
        case syncing

        /// The latest synchronization attempt failed with a human-readable message.
        case failed(String)
    }

    /**
     Describes the destructive confirmation step that follows Android's adopt-versus-create prompt.

     Android first asks whether a same-named remote folder should be adopted or replaced, then
     presents a second confirmation explaining which side will be reset. iOS preserves the same
     two-step flow so the user must explicitly confirm destructive local or remote replacement.
     */
    private enum PendingRemoteConfirmation: Identifiable, Equatable {
        /// Confirm replacing local content with the discovered remote folder.
        case resetLocal(RemoteSyncBootstrapCandidate)

        /// Confirm replacing the discovered remote folder with local content.
        case resetCloud(RemoteSyncBootstrapCandidate)

        /// Stable alert identity derived from the category and confirmation branch.
        var id: String {
            switch self {
            case .resetLocal(let candidate):
                return "reset-local-\(candidate.category.rawValue)"
            case .resetCloud(let candidate):
                return "reset-cloud-\(candidate.category.rawValue)"
            }
        }

        /// Sync category affected by the pending destructive choice.
        var category: RemoteSyncCategory {
            switch self {
            case .resetLocal(let candidate), .resetCloud(let candidate):
                return candidate.category
            }
        }
    }

    /**
     Creates the sync settings screen with environment-provided sync services and settings storage.
     */
    public init() {}

    /**
     Builds backend selection, iCloud controls, and remote-backend configuration sections.
     */
    public var body: some View {
        Form {
            backendSection

            if selectedBackend == .iCloud {
                iCloudSections
            } else if selectedBackend == .nextCloud {
                nextCloudSections
            } else if selectedBackend == .googleDrive {
                googleDriveSections
            }
        }
        .accessibilityIdentifier("syncSettingsScreen")
        .accessibilityValue(syncSettingsAccessibilityValue)
        .overlay(alignment: .topLeading) {
            syncSettingsStateProbe
        }
        .navigationTitle(String(localized: "sync_adapter"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            loadPersistedSettingsIfNeeded()
        }
        .onDisappear {
            persistRemoteSettings()
        }
        .onChange(of: selectedBackend) { _, newValue in
            remoteSettingsStore.selectedBackend = newValue
            remoteConnectionStatus = nil
            if newValue == .googleDrive {
                Task {
                    await googleDriveAuthService.restorePreviousSignInIfNeeded()
                }
            }
        }
        .alert(
            String(localized: "cloud_sync_title"),
            isPresented: Binding(
                get: { pendingRemoteAdoption != nil },
                set: { newValue in
                    if !newValue {
                        pendingRemoteAdoption = nil
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
            }
        } message: { confirmation in
            Text(remoteConfirmationMessage(for: confirmation))
        }
        .confirmationDialog(
            String(localized: "disable_sync_title"),
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "disable_sync"), role: .destructive) {
                syncService.toggleSync()
                showRestartAlert = true
            }
        } message: {
            Text(String(localized: "disable_sync_warning"))
        }
        .alert(String(localized: "restart_required"), isPresented: $showRestartAlert) {
            Button(String(localized: "ok")) {}
        } message: {
            Text(String(localized: "restart_to_apply_sync"))
        }
        .confirmationDialog(
            String(localized: "cloud_sync_title"),
            isPresented: $showGoogleDriveResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "google_drive_sign_out"), role: .destructive) {
                resetGoogleDriveSynchronization()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "sync_confirmation"))
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

    /**
     Backend selection section shared by all sync modes.
     */
    private var backendSection: some View {
        Section {
            Picker(String(localized: "sync_adapter"), selection: $selectedBackend) {
                Text(String(localized: "icloud_sync"))
                    .tag(RemoteSyncBackend.iCloud)
                    .accessibilityIdentifier("syncBackendOption::\(RemoteSyncBackend.iCloud.rawValue)")
                Text(String(localized: "adapters_next_cloud"))
                    .tag(RemoteSyncBackend.nextCloud)
                    .accessibilityIdentifier("syncBackendOption::\(RemoteSyncBackend.nextCloud.rawValue)")
                Text(String(localized: "adapters_google_drive"))
                    .tag(RemoteSyncBackend.googleDrive)
                    .accessibilityIdentifier("syncBackendOption::\(RemoteSyncBackend.googleDrive.rawValue)")
            }
            .accessibilityIdentifier("syncBackendPicker")

        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "prefs_sync_introduction_summary1"))
                if selectedBackend == .googleDrive {
                    Text(
                        String(
                            format: String(localized: "prefs_sync_introduction_summary2"),
                            appDisplayName
                        )
                    )
                }
                Text(String(format: String(localized: "sync_adapter_summary"), selectedBackendTitle))
            }
        }
    }

    /**
     Groups the existing CloudKit-only sections so they can be hidden when another backend is
     selected.
     */
    private var iCloudSections: some View {
        Group {
            Section {
                Toggle(String(localized: "icloud_sync_enabled"), isOn: Binding(
                    get: { syncService.isEnabled },
                    set: { newValue in
                        if !newValue {
                            showDisableConfirmation = true
                        } else {
                            syncService.toggleSync()
                            showRestartAlert = true
                        }
                    }
                ))
                .disabled(syncService.requiresRestart)
                Text(String(localized: "icloud_sync_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "icloud_sync"))
            }

            Section {
                HStack {
                    Text(String(localized: "status"))
                    Spacer()
                    iCloudStatusView
                }

                if syncService.isEnabled && !syncService.requiresRestart {
                    HStack {
                        Text(String(localized: "icloud_account"))
                        Spacer()
                        Text(accountText)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(String(localized: "last_sync"))
                        Spacer()
                        Text(lastSyncText)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(String(localized: "sync_status"))
            }

            if syncService.isEnabled && !syncService.requiresRestart {
                Section {
                    Text(String(localized: "sync_what_syncs"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(String(localized: "sync_data_included"))
                }
            }
        }
    }

    /**
     Groups NextCloud/WebDAV credential editing and connection-testing UI.
     */
    private var nextCloudSections: some View {
        Group {
            Section {
                TextField(String(localized: "auth_server_uri"), text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("syncNextCloudServerURLField")
                    #if os(iOS)
                    .textContentType(.URL)
                    #endif

                TextField(String(localized: "auth_username"), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("syncNextCloudUsernameField")
                    #if os(iOS)
                    .textContentType(.username)
                    #endif

                SecureField(String(localized: "auth_password"), text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("syncNextCloudPasswordField")
                    #if os(iOS)
                    .textContentType(.password)
                    #endif

                TextField(String(localized: "auth_folder_path"), text: $folderPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("syncNextCloudFolderPathField")
            } header: {
                Text(String(localized: "adapters_next_cloud"))
            } footer: {
                Text(String(localized: "auth_folder_path_summary"))
            }

            Section {
                Button(String(localized: "test_connection")) {
                    Task {
                        await testRemoteConnection()
                    }
                }
                .disabled(isTestingConnection)
                .accessibilityIdentifier("syncNextCloudTestConnectionButton")

                HStack(alignment: .top) {
                    Text(String(localized: "status"))
                    Spacer()
                    remoteStatusView
                }
                .accessibilityIdentifier("syncRemoteStatus")
                .accessibilityValue(remoteStatusAccessibilityValue)
            } header: {
                Text(String(localized: "sync_status"))
            }

            Section {
                remoteCategoryList
            } header: {
                Text(String(localized: "synchronization_categories"))
            }
        }
    }

    /**
     Groups Google Drive auth status and Android-style category toggles.
     */
    private var googleDriveSections: some View {
        Group {
            Section {
                HStack(alignment: .top) {
                    Text(String(localized: "status"))
                    Spacer()
                    googleDriveStatusView
                }

                if let accountLabel = googleDriveAuthService.currentAccountLabel {
                    HStack {
                        Text(String(localized: "google_drive_account"))
                        Spacer()
                        Text(accountLabel)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Button(String(localized: "google_drive_sign_in")) {
                    Task {
                        await signInToGoogleDrive()
                    }
                }
                .disabled(isGoogleDriveSignInButtonDisabled)
                .accessibilityIdentifier("syncGoogleDriveSignInButton")

                if case .signedIn = googleDriveAuthService.state {
                    Button(String(localized: "google_drive_sign_out"), role: .destructive) {
                        showGoogleDriveResetConfirmation = true
                    }
                }
            } header: {
                Text(String(localized: "adapters_google_drive"))
            }

            Section {
                remoteCategoryList
            } header: {
                Text(String(localized: "synchronization_categories"))
            }
        }
    }

    /**
     Shared Android-style remote category toggle list used by supported remote backends.
     */
    private var remoteCategoryList: some View {
        ForEach(RemoteSyncCategory.allCases, id: \.self) { category in
            let categoryBinding = remoteCategoryBinding(for: category)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        categoryBinding.wrappedValue.toggle()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(remoteCategoryTitle(for: category))
                            Text(remoteCategoryContentDescription(for: category))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let supplementalText = remoteCategorySupplementalText(for: category) {
                                Text(supplementalText)
                                    .font(.caption)
                                    .foregroundStyle(remoteCategorySupplementalColor(for: category))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("syncCategoryToggle::\(category.rawValue)")
                    .accessibilityValue(remoteCategoryAccessibilityValue(for: category))

                    Toggle("", isOn: categoryBinding)
                        .labelsHidden()
                        .accessibilityIdentifier("syncCategoryToggleSwitch::\(category.rawValue)")
                        .accessibilityValue(remoteCategoryAccessibilityValue(for: category))
                }
                .disabled(isRemoteSyncInteractionLocked)

            }
        }
    }

    /**
     Builds the trailing status label for the current iCloud runtime state.
     */
    @ViewBuilder
    private var iCloudStatusView: some View {
        switch syncService.state {
        case .disabled:
            SwiftUI.Label(String(localized: "sync_disabled"), systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        case .noAccount:
            SwiftUI.Label(String(localized: "no_icloud_account"), systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.red)
        case .idle:
            SwiftUI.Label(String(localized: "sync_active"), systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .syncing:
            SwiftUI.Label(String(localized: "syncing"), systemImage: "arrow.triangle.2.circlepath.icloud")
                .foregroundStyle(.blue)
        case .pendingRestart:
            SwiftUI.Label(String(localized: "restart_to_apply_sync"), systemImage: "arrow.clockwise.icloud")
                .foregroundStyle(.orange)
        case .error(let msg):
            SwiftUI.Label(msg, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        }
    }

    /**
     Builds the trailing connection-test state for the NextCloud/WebDAV section.
     */
    @ViewBuilder
    private var remoteStatusView: some View {
        if isTestingConnection {
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "loading"))
                    .foregroundStyle(.secondary)
            }
        } else if let remoteConnectionStatus {
            switch remoteConnectionStatus {
            case .success:
                SwiftUI.Label(String(localized: "ok"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                SwiftUI.Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
        } else {
            Text("—")
                .foregroundStyle(.secondary)
        }
    }

    /**
     Accessibility-exported state for the NextCloud/WebDAV connection-test row.

     The UI suite uses a stable semantic token instead of matching localized status strings.
     This keeps the workflow assertion deterministic while leaving the visible user-facing copy
     unchanged.
     */
    private var remoteStatusAccessibilityValue: String {
        if isTestingConnection {
            return "testing"
        }

        guard let remoteConnectionStatus else {
            return "idle"
        }

        switch remoteConnectionStatus {
        case .success:
            return "success"
        case .failure(let message):
            let invalidURLMessage = String(localized: "invalid_url_message")
            return message == invalidURLMessage ? "failureInvalidURL" : "failure"
        }
    }

    /**
     Accessibility-exported state for one remote sync category toggle.

     The UI suite uses stable semantic tokens instead of localized toggle labels or platform-
     specific switch values so assertions remain deterministic across locales and SwiftUI control
     rendering differences.

     - Parameter category: Remote sync category whose current persisted or in-memory enabled state
       should be exported.
     - Returns: `enabled` when the category is currently on, otherwise `disabled`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remoteCategoryAccessibilityValue(for category: RemoteSyncCategory) -> String {
        let isEnabled = isRemoteCategoryEnabled(category)
        return isEnabled ? "enabled" : "disabled"
    }

    /**
     Stable root-screen state exported for Sync UI automation.

     The token captures the active backend plus the currently enabled remote categories so UI tests
     can assert state changes without relying on localized row text or SwiftUI switch internals.

     - Returns: A deterministic `backend=<raw>;enabled=<csv-or-none>` token.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var syncSettingsAccessibilityValue: String {
        let enabledCategories = RemoteSyncCategory.allCases
            .filter(isRemoteCategoryEnabled)
            .map(\.rawValue)
            .sorted()
        let enabledToken = enabledCategories.isEmpty ? "none" : enabledCategories.joined(separator: ",")
        return "backend=\(selectedBackend.rawValue);enabled=\(enabledToken)"
    }

    /**
     Hidden accessibility probe used by UI tests to observe the live sync-state token.

     SwiftUI's `Form` wrapper can lag behind nested state mutations when XCTest reads the
     collection view's exported value directly. This dedicated probe mirrors the same semantic
     token without changing the visible layout.
     */
    @ViewBuilder
    private var syncSettingsStateProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("syncSettingsState")
            .accessibilityLabel("")
            .accessibilityValue(syncSettingsAccessibilityValue)
    }

    /**
     Returns the currently effective enabled state for one remote sync category.

     - Parameter category: Category whose in-memory or persisted enabled state should be resolved.
     - Returns: `true` when the category is currently enabled, otherwise `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func isRemoteCategoryEnabled(_ category: RemoteSyncCategory) -> Bool {
        remoteCategoryEnabled[category] ?? remoteSettingsStore.isSyncEnabled(for: category)
    }

    /**
     Builds the trailing auth/session state for the Google Drive section.
     */
    @ViewBuilder
    private var googleDriveStatusView: some View {
        switch googleDriveAuthService.state {
        case .notConfigured(let message):
            SwiftUI.Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        case .signedOut:
            SwiftUI.Label(String(localized: "google_drive_not_signed_in"), systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.secondary)
        case .authenticating:
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "loading"))
                    .foregroundStyle(.secondary)
            }
        case .signedIn(_, let driveAccessGranted):
            if driveAccessGranted {
                SwiftUI.Label(String(localized: "ok"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                SwiftUI.Label(String(localized: "google_drive_permission_required"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
        case .error(let message):
            SwiftUI.Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }

    /**
     Binding used by the Android-style category toggles in the remote-backend sections.

     Side effects:
       - enabling a category persists the Android `gdrive_*` toggle and starts synchronization
       - disabling a category persists the Android `gdrive_*` toggle immediately and clears
         transient UI state
     */
    private func remoteCategoryBinding(for category: RemoteSyncCategory) -> Binding<Bool> {
        Binding(
            get: { remoteCategoryEnabled[category] ?? remoteSettingsStore.isSyncEnabled(for: category) },
            set: { newValue in
                if newValue {
                    remoteCategoryEnabled[category] = true
                    Task {
                        await beginRemoteSynchronization(for: category)
                    }
                } else {
                    disableRemoteSync(for: category)
                }
            }
        )
    }

    /**
     Whether category toggles should be locked while remote synchronization UI is in a modal state.

     Failure modes:
     - returns `true` during connection tests, in-flight category sync, or pending confirmation prompts
     */
    private var isRemoteSyncInteractionLocked: Bool {
        if isTestingConnection || pendingRemoteAdoption != nil || pendingRemoteConfirmation != nil {
            return true
        }

        return remoteCategoryStatuses.values.contains { status in
            if case .syncing = status {
                return true
            }
            return false
        }
    }

    /**
     Whether the Google Drive sign-in button should be disabled.
     *
     * Failure modes:
     * - returns `true` while remote sync is already in flight or the auth service is authenticating
     */
    private var isGoogleDriveSignInButtonDisabled: Bool {
        if isRemoteSyncInteractionLocked {
            return true
        }

        switch googleDriveAuthService.state {
        case .notConfigured:
            return true
        case .authenticating:
            return true
        case .signedIn(_, let driveAccessGranted):
            return driveAccessGranted
        default:
            return false
        }
    }

    /**
     Human-readable backend name used in the backend summary footer.
     */
    private var selectedBackendTitle: String {
        switch selectedBackend {
        case .iCloud:
            return String(localized: "icloud_sync")
        case .nextCloud:
            return String(localized: "adapters_next_cloud")
        case .googleDrive:
            return String(localized: "adapters_google_drive")
        }
    }

    /**
     Display name used in Android's Google Drive permission-summary footer.
     */
    private var appDisplayName: String {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let resolved = displayName ?? bundleName ?? "AndBible"
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "AndBible" : trimmed
    }

    /**
     Store wrapper used to read and write local remote-sync configuration.

     Side effects:
     - each access materializes a fresh `SettingsStore` and `RemoteSyncSettingsStore` against the
       current `modelContext`
     */
    private var remoteSettingsStore: RemoteSyncSettingsStore {
        RemoteSyncSettingsStore(settingsStore: SettingsStore(modelContext: modelContext))
    }

    /**
     Loads persisted backend and NextCloud/WebDAV settings into local view state exactly once.

     Side effects:
     - reads backend selection from SwiftData-backed local settings
     - reads WebDAV password from Keychain through `RemoteSyncSettingsStore`
     - mutates view state for the picker and credential fields

     Failure modes:
     - missing credential fields simply leave the corresponding local form fields empty
     */
    private func loadPersistedSettingsIfNeeded() {
        guard !hasLoadedSettings else {
            return
        }

        selectedBackend = remoteSettingsStore.selectedBackend

        if let configuration = remoteSettingsStore.loadWebDAVConfiguration() {
            serverURL = configuration.serverURL
            username = configuration.username
            folderPath = configuration.folderPath ?? ""
        }
        password = remoteSettingsStore.webDAVPassword() ?? ""
        remoteCategoryEnabled = Dictionary(
            uniqueKeysWithValues: RemoteSyncCategory.allCases.map { category in
                (category, remoteSettingsStore.isSyncEnabled(for: category))
            }
        )
        hasLoadedSettings = true
    }

    /**
     Persists the currently edited remote-sync state.

     Side effects:
     - writes the selected backend to `sync_adapter`
     - writes WebDAV server, username, folder path, and password through `RemoteSyncSettingsStore`
       into SwiftData and Keychain

     Failure modes:
     - persistence errors from Keychain writes are swallowed because this view should not crash on
       local settings save failures; the user still receives connection-test feedback separately
     */
    private func persistRemoteSettings() {
        let store = remoteSettingsStore
        store.selectedBackend = selectedBackend
        try? store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: serverURL,
                username: username,
                folderPath: normalizedFolderPath
            ),
            password: password
        )
    }

    /**
     Starts an interactive Google Drive sign-in or scope-consent flow.
     *
     * Side effects:
     * - may present Google Sign-In or scope-consent UI
     * - updates the global remote-sync alert state when sign-in fails
     *
     * Failure modes:
     * - sign-in failures surface their localized description through `remoteSyncErrorMessage`
     */
    @MainActor
    private func signInToGoogleDrive() async {
        do {
            try await googleDriveAuthService.signInInteractively()
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteSyncErrorMessage = message.isEmpty ? String(localized: "sign_in_failed") : message
        }
    }

    /**
     Signs out of Google Drive and clears Android-aligned local sync bookkeeping.
     *
     * Side effects:
     * - signs the Google account out through `GoogleDriveAuthService`
     * - clears local remote-sync metadata through `RemoteSyncResetService`
     * - resets transient category UI state and pending prompts
     *
     * Failure modes:
     * - local bookkeeping clears are best-effort through the underlying settings-backed stores
     */
    @MainActor
    private func resetGoogleDriveSynchronization() {
        googleDriveAuthService.signOut()
        RemoteSyncResetService(settingsStore: SettingsStore(modelContext: modelContext))
            .resetAllCategories()
        remoteCategoryEnabled = [:]
        remoteCategoryStatuses = [:]
        pendingRemoteAdoption = nil
        pendingRemoteConfirmation = nil
        remoteConnectionStatus = nil
        remoteSyncErrorMessage = nil
    }

    /**
     Starts Android-style synchronization for one enabled remote category.

     The first pass mirrors Android's `setupDrivePref()` path:
     - persist the category toggle as enabled
     - inspect bootstrap state
     - automatically create a new remote folder when no folder exists
     - surface the adopt-versus-create prompt when a same-named remote folder already exists

     - Parameter category: Logical sync category the user just enabled.
     - Side effects:
       - persists the current backend configuration before synchronization starts
       - may present interactive Google sign-in when Google Drive is selected and no ready session exists
       - may perform remote bootstrap validation, initial-backup restore, or sparse patch sync
       - may present adopt-versus-create alerts by mutating view state
     - Failure modes:
       - invalid or incomplete backend configuration disables the category again and surfaces an error
       - transport or synchronization failures leave the category enabled to match Android's retry semantics, while surfacing the latest error
     */
    @MainActor
    private func beginRemoteSynchronization(for category: RemoteSyncCategory) async {
        persistRemoteSettings()

        do {
            if selectedBackend == .googleDrive && !googleDriveAuthService.isReadyForSync {
                try await googleDriveAuthService.signInInteractively()
            }

            let service = try makeRemoteSynchronizationService()
            let settingsStore = SettingsStore(modelContext: modelContext)

            remoteSettingsStore.setSyncEnabled(true, for: category)
            remoteCategoryEnabled[category] = true
            remoteCategoryStatuses[category] = .syncing

            do {
                let outcome = try await service.synchronize(
                    category,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )

                switch outcome {
                case .synchronized(let report):
                    remoteCategoryStatuses[category] = .idle
                    finishRemoteSynchronization(with: report, for: category)
                case .requiresRemoteAdoption(let candidate):
                    pendingRemoteAdoption = candidate
                    remoteCategoryStatuses[category] = .idle
                case .requiresRemoteCreation:
                    let report = try await service.createRemoteFolderAndSynchronize(
                        for: category,
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                    remoteCategoryStatuses[category] = .idle
                    finishRemoteSynchronization(with: report, for: category)
                }
            } catch {
                handleRemoteSynchronizationError(error, for: category, revertEnablement: false)
            }
        } catch {
            handleRemoteSynchronizationError(error, for: category, revertEnablement: true)
        }
    }

    /**
     Continues synchronization after the user confirmed adopting or replacing a discovered remote folder.

     - Parameter confirmation: Destructive action the user confirmed.
     - Side effects:
       - may overwrite local or remote category state through the synchronization coordinator
       - updates transient category status and error alert state
     - Failure modes:
       - transport or synchronization failures surface an alert and keep the category enabled so the
         user can retry later, matching Android's behavior after a failed sync attempt
     */
    @MainActor
    private func continueRemoteSynchronization(after confirmation: PendingRemoteConfirmation) async {
        let category = confirmation.category
        remoteCategoryStatuses[category] = .syncing

        do {
            let service = try makeRemoteSynchronizationService()
            let settingsStore = SettingsStore(modelContext: modelContext)
            let report: RemoteSyncCategorySynchronizationReport

            switch confirmation {
            case .resetLocal(let candidate):
                report = try await service.adoptRemoteFolderAndSynchronize(
                    for: candidate.category,
                    remoteFolderID: candidate.remoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            case .resetCloud(let candidate):
                report = try await service.createRemoteFolderAndSynchronize(
                    for: candidate.category,
                    replacingRemoteFolderID: candidate.remoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }

            remoteCategoryStatuses[category] = .idle
            finishRemoteSynchronization(with: report, for: category)
        } catch {
            handleRemoteSynchronizationError(error, for: category, revertEnablement: false)
        }
    }

    /**
     Applies the successful result of one category synchronization pass to the local UI state.

     - Parameters:
       - report: Completed synchronization report.
       - category: Logical sync category that finished.
     - Side effects:
       - refreshes the toggle state from persisted settings
       - clears any stale per-category failure message
     - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func finishRemoteSynchronization(
        with report: RemoteSyncCategorySynchronizationReport,
        for category: RemoteSyncCategory
    ) {
        remoteCategoryEnabled[category] = remoteSettingsStore.isSyncEnabled(for: report.category)
        remoteCategoryStatuses[category] = .idle
    }

    /**
     Disables one Android-style remote sync category immediately.

     - Parameter category: Logical sync category to disable.
     - Side effects:
       - writes the Android `gdrive_*` toggle as `false`
       - clears transient in-flight or error UI state for the category
     - Failure modes:
       - `SettingsStore` write failures are swallowed by `RemoteSyncSettingsStore`
     */
    @MainActor
    private func disableRemoteSync(for category: RemoteSyncCategory) {
        remoteSettingsStore.setSyncEnabled(false, for: category)
        remoteCategoryEnabled[category] = false
        remoteCategoryStatuses[category] = .idle
    }

    /**
     Maps synchronization errors into Android-aligned user-visible state.

     - Parameters:
       - error: Failure emitted by remote settings validation or synchronization services.
       - category: Logical sync category that was being synchronized.
       - revertEnablement: Whether the category toggle should be turned off after the failure.
     - Side effects:
       - may disable the category toggle for validation or incompatibility failures
       - stores a per-category failure message and presents a global alert
     - Failure modes: This helper cannot fail.
     */
    @MainActor
    private func handleRemoteSynchronizationError(
        _ error: Error,
        for category: RemoteSyncCategory,
        revertEnablement: Bool
    ) {
        let message: String

        switch error {
        case WebDAVClientError.invalidURL:
            message = String(localized: "invalid_url_message")
        case RemoteSyncSynchronizationServiceFactoryError.invalidWebDAVConfiguration:
            message = String(localized: "invalid_url_message")
        case RemoteSyncSynchronizationServiceFactoryError.missingWebDAVPassword:
            message = String(localized: "sign_in_failed")
        case RemoteSyncSynchronizationServiceFactoryError.googleDriveAuthenticationRequired:
            message = String(localized: "google_drive_not_signed_in")
        case let authError as GoogleDriveAuthServiceError:
            message = authError.localizedDescription
        case RemoteSyncPatchDiscoveryError.incompatiblePatchVersion:
            disableRemoteSync(for: category)
            message = [
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
            message = localizedMessage.isEmpty ? String(localized: "sync_error") : localizedMessage
            if revertEnablement {
                disableRemoteSync(for: category)
            }
        }

        remoteCategoryStatuses[category] = .failed(message)
        remoteSyncErrorMessage = message
    }

    /**
     Creates a backend-specific synchronization coordinator from the current settings state.

     - Returns: Configured synchronization service bound to the currently selected remote backend.
     - Side effects:
       - reads and may generate the stable remote device identifier through `RemoteSyncSettingsStore`
     - Failure modes:
       - throws `RemoteSyncSynchronizationServiceFactoryError` when the selected backend is missing
         required local configuration or authentication state
       - throws `WebDAVClientError.invalidURL` when the stored NextCloud server URL cannot be normalized
     */
    private func makeRemoteSynchronizationService() throws -> RemoteSyncSynchronizationService {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.andbible.ios"
        let factory = RemoteSyncSynchronizationServiceFactory(
            bundleIdentifier: bundleIdentifier,
            googleDriveAccessTokenProvider: { [googleDriveAuthService] in
                try await googleDriveAuthService.accessToken()
            }
        )
        return try factory.makeSynchronizationService(using: remoteSettingsStore)
    }

    /**
     Returns the localized category title used by the Android-style remote sync toggles.

     - Parameter category: Logical sync category to label.
     - Returns: Localized category title.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remoteCategoryTitle(for category: RemoteSyncCategory) -> String {
        switch category {
        case .bookmarks:
            return String(localized: "bookmarks")
        case .workspaces:
            return String(localized: "help_workspaces_title")
        case .readingPlans:
            return String(localized: "reading_plans_plural")
        }
    }

    /**
     Returns Android's category description string for the supplied sync category.

     - Parameter category: Logical sync category to describe.
     - Returns: Localized Android-aligned category description.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
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
     Returns the transient status or last-updated caption shown beneath one category toggle.

     - Parameter category: Logical sync category to describe.
     - Returns: Supplemental caption text, or `nil` when nothing extra should be shown.
     - Side effects: Reads the persisted remote progress state when no transient status is active.
     - Failure modes: Missing sync timestamps produce `nil`.
     */
    private func remoteCategorySupplementalText(for category: RemoteSyncCategory) -> String? {
        if let status = remoteCategoryStatuses[category] {
            switch status {
            case .idle:
                break
            case .syncing:
                return String(localized: "synchronizing")
            case .failed(let message):
                return message
            }
        }

        guard remoteCategoryEnabled[category] ?? remoteSettingsStore.isSyncEnabled(for: category) else {
            return nil
        }

        let progressState = RemoteSyncStateStore(settingsStore: SettingsStore(modelContext: modelContext))
            .progressState(for: category)
        guard let lastSynchronized = progressState.lastSynchronized, lastSynchronized > 0 else {
            return nil
        }

        return String(
            format: String(localized: "last_updated"),
            formattedSyncTimestamp(milliseconds: lastSynchronized)
        )
    }

    /**
     Returns the color used for the supplemental category caption.

     - Parameter category: Logical sync category being rendered.
     - Returns: Semantic color for the category's supplemental caption.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remoteCategorySupplementalColor(for category: RemoteSyncCategory) -> Color {
        switch remoteCategoryStatuses[category] ?? .idle {
        case .idle:
            return .secondary
        case .syncing:
            return .secondary
        case .failed:
            return .orange
        }
    }

    /**
     Returns the localized destructive-confirmation message for one adopt-or-replace choice.

     - Parameter confirmation: Pending destructive confirmation branch.
     - Returns: Localized confirmation body text.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remoteConfirmationMessage(for confirmation: PendingRemoteConfirmation) -> String {
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
     Formats an Android-style absolute sync timestamp for category summaries.

     - Parameter milliseconds: Milliseconds since 1970.
     - Returns: Timestamp formatted as `dd-MM-yyyy HH:mm:ss`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func formattedSyncTimestamp(milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "dd-MM-yyyy HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0))
    }

    /**
     Runs a manual NextCloud/WebDAV connection test against the current form values.

     The test uses the same Android-compatible server-root semantics as the persisted config:
     `WebDAVSyncConfiguration` resolves the stored server root into a DAV endpoint before issuing a
     root-level `PROPFIND`.

     Side effects:
     - persists the current form values before testing so later sync flows use the same settings
     - performs a network request using `WebDAVClient.testConnection()`
     - updates transient view state for progress and status feedback

     Failure modes:
     - invalid local URL input is converted into the Android-derived `invalid_url_message`
     - transport or authentication failures surface the underlying localized error when available,
       otherwise they fall back to `sign_in_failed`
     */
    @MainActor
    private func testRemoteConnection() async {
        isTestingConnection = true
        remoteConnectionStatus = nil
        persistRemoteSettings()
        defer { isTestingConnection = false }

        do {
            let configuration = WebDAVSyncConfiguration(
                serverURL: serverURL,
                username: username,
                folderPath: normalizedFolderPath
            )
            let client = try configuration.makeWebDAVClient(password: password)
            _ = try await client.testConnection()
            remoteConnectionStatus = .success
        } catch WebDAVClientError.invalidURL {
            remoteConnectionStatus = .failure(String(localized: "invalid_url_message"))
        } catch {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteConnectionStatus = .failure(
                message.isEmpty ? String(localized: "sign_in_failed") : message
            )
        }
    }

    /**
     Normalizes the optional folder path before persistence and transport use.

     - Returns: Trimmed folder path, or `nil` when the user left the field empty.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var normalizedFolderPath: String? {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /**
     Human-readable iCloud account description shown in the iCloud status section.
     */
    private var accountText: String {
        switch syncService.state {
        case .noAccount:
            return String(localized: "no_icloud_account")
        default:
            return syncService.accountDescription ?? "—"
        }
    }

    /**
     Relative last-sync timestamp shown in the iCloud status section.

     Failure modes:
     - returns an em dash placeholder when no sync timestamp has been recorded yet
     */
    private var lastSyncText: String {
        guard let date = syncService.lastSyncDate else {
            return "—"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
