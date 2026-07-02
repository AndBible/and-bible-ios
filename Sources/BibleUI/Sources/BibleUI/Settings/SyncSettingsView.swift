// SyncSettingsView.swift — Sync backend settings

import SwiftUI
import SwiftData
import BibleCore

/**
 Configures the active sync backend and surfaces backend-specific settings.

 The screen acts as the entry point for the existing CloudKit implementation plus the Android-
 aligned NextCloud/WebDAV backend. It preserves the current iCloud toggle/status flow while
 allowing the remote backend to edit credentials and perform category-scoped synchronization
 without changing the active CloudKit runtime mid-session.

 Data dependencies:
 - `SyncService` provides the effective iCloud sync mode, account description, runtime state, and
   last known sync timestamp
 - SwiftData's environment `modelContext` provides access to `SettingsStore` through
   `RemoteSyncSettingsStore`
 - localized strings provide backend labels, field titles, status text, and warnings

 Side effects:
 - changing the selected backend persists `sync_adapter` through `RemoteSyncSettingsStore`
 - editing WebDAV credentials updates local state and can be persisted to SwiftData plus Keychain
 - testing a NextCloud/WebDAV connection builds a transient `WebDAVClient` and performs a network
   request against the configured server
 - toggling iCloud sync calls back into `SyncService`; the production app applies it live, while
   preview or test hosts without an installed runtime handler can still surface restart-required
   fallback state
 - disabling iCloud sync first presents a confirmation dialog before mutating the service state
 */
public struct SyncSettingsView: View {
    /// Shared CloudKit sync service injected from the app environment.
    @Environment(SyncService.self) private var syncService

    /// SwiftData context used to materialize the local settings store.
    @Environment(\.modelContext) private var modelContext

    /// Whether the destructive disable-sync confirmation dialog is presented.
    @State private var showDisableConfirmation = false

    /// Currently selected sync backend shown in the backend picker.
    @State private var selectedBackend: RemoteSyncBackend = .iCloud

    /// User-entered or persisted NextCloud/WebDAV server root URL.
    @State private var serverURL = ""

    /// Last server URL accepted by Android-style edit validation and eligible for persistence.
    @State private var lastCommittedServerURL = ""

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

    /// Global remote-sync error message shown in an alert after a category sync failure.
    @State private var remoteSyncErrorMessage: String?

    /// Last successfully completed confirmation branch exported only for UI-test assertions.
    @State private var lastRemoteConfirmationAction: String?

    /// Currently focused inline NextCloud credential field, used to mirror Android edit commits.
    @FocusState private var focusedNextCloudCredentialField: NextCloudCredentialField?

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
     Focusable inline credential fields that should apply Android preference-edit behavior.

     Android's `EditTextPreference` validates and either accepts or rejects values when the edit
     dialog commits. iOS renders these settings inline, so focus transitions and submit actions are
     the equivalent commit boundary.
     */
    private enum NextCloudCredentialField: Hashable {
        /// NextCloud/WebDAV server root URL.
        case serverURL
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
        }
        .onChange(of: focusedNextCloudCredentialField) { oldValue, newValue in
            if oldValue == .serverURL, newValue != .serverURL {
                _ = validateNextCloudServerURLAfterEditing()
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedNextCloudCredentialField == .serverURL {
                    Spacer()
                    Button(String(localized: "ok")) {
                        _ = validateNextCloudServerURLAfterEditing()
                        focusedNextCloudCredentialField = nil
                    }
                    .accessibilityIdentifier("syncNextCloudServerURLCommitButton")
                }
            }
        }
        #endif
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
            }
        } message: {
            Text(String(localized: "disable_sync_warning"))
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
            Picker(selection: $selectedBackend) {
                Text(String(localized: "icloud_sync"))
                    .tag(RemoteSyncBackend.iCloud)
                    .accessibilityIdentifier("syncBackendOption::\(RemoteSyncBackend.iCloud.rawValue)")
                Text(String(localized: "adapters_next_cloud"))
                    .tag(RemoteSyncBackend.nextCloud)
                    .accessibilityIdentifier("syncBackendOption::\(RemoteSyncBackend.nextCloud.rawValue)")
            } label: {
                syncSettingsRowLabel(
                    SyncSettingsPresentation.backend,
                    title: String(localized: "sync_adapter"),
                    summary: String(localized: "prefs_sync_introduction_summary1"),
                    detail: String(format: String(localized: "sync_adapter_summary"), selectedBackendTitle)
                )
            }
            .accessibilityIdentifier("syncBackendPicker")
        }
    }

    /**
     Groups the existing CloudKit-only sections so they can be hidden when another backend is
     selected.
     */
    private var iCloudSections: some View {
        Group {
            Section {
                Toggle(isOn: Binding(
                    get: { syncService.isEnabled },
                    set: { newValue in
                        guard newValue != syncService.isEnabled else {
                            return
                        }
                        if !newValue {
                            showDisableConfirmation = true
                        } else {
                            syncService.toggleSync()
                        }
                    }
                )) {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.backend,
                        title: String(localized: "icloud_sync_enabled"),
                        summary: String(localized: "icloud_sync_description"),
                        isEnabled: isICloudToggleEnabled
                    )
                }
                .disabled(!isICloudToggleEnabled)
                .accessibilityIdentifier("syncICloudEnabledToggle")
            } header: {
                syncSettingsSectionHeader(String(localized: "icloud_sync"))
            }

            Section {
                LabeledContent {
                    iCloudStatusView
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.syncInfo,
                        title: String(localized: "status")
                    )
                }

                if syncService.isEnabled && !syncService.requiresRestart {
                    LabeledContent {
                        Text(accountText)
                            .foregroundStyle(.secondary)
                    } label: {
                        syncSettingsRowLabel(
                            SyncSettingsPresentation.nextCloudCredential,
                            title: String(localized: "icloud_account")
                        )
                    }

                    LabeledContent {
                        Text(lastSyncText)
                            .foregroundStyle(.secondary)
                    } label: {
                        syncSettingsRowLabel(
                            SyncSettingsPresentation.syncInfo,
                            title: String(localized: "last_sync")
                        )
                    }
                }
            } header: {
                syncSettingsSectionHeader(String(localized: "sync_status"))
            }

            if syncService.isEnabled && !syncService.requiresRestart {
                Section {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.syncInfo,
                        title: String(localized: "sync_data_included"),
                        summary: String(localized: "sync_what_syncs")
                    )
                } header: {
                    syncSettingsSectionHeader(String(localized: "sync_data_included"))
                }
            }
        }
    }

    /**
     Returns whether the iCloud toggle should accept another user change.

     Live runtime rebuilds complete synchronously from the settings screen, but the transient
     `.syncing` state still protects the control from repeated taps while SwiftUI is reconciling
     the updated data stack.
     */
    private var isICloudToggleEnabled: Bool {
        !syncService.requiresRestart && syncService.state != .syncing
    }

    /**
     Groups NextCloud/WebDAV credential editing and connection-testing UI.
     */
    private var nextCloudSections: some View {
        Group {
            Section {
                LabeledContent {
                    TextField(String(localized: "auth_server_uri"), text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .focused($focusedNextCloudCredentialField, equals: .serverURL)
                        .onSubmit {
                            _ = validateNextCloudServerURLAfterEditing()
                            focusedNextCloudCredentialField = nil
                        }
                        .accessibilityIdentifier("syncNextCloudServerURLField")
                        #if os(iOS)
                        .textContentType(.URL)
                        .submitLabel(.done)
                        #endif
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.nextCloudCredential,
                        title: String(localized: "auth_server_uri")
                    )
                }

                LabeledContent {
                    TextField(String(localized: "auth_username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("syncNextCloudUsernameField")
                        #if os(iOS)
                        .textContentType(.username)
                        #endif
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.nextCloudCredential,
                        title: String(localized: "auth_username")
                    )
                }

                LabeledContent {
                    SecureField(String(localized: "auth_password"), text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("syncNextCloudPasswordField")
                        #if os(iOS)
                        .textContentType(.password)
                        #endif
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.nextCloudCredential,
                        title: String(localized: "auth_password")
                    )
                }

                LabeledContent {
                    TextField(String(localized: "auth_folder_path"), text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("syncNextCloudFolderPathField")
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.nextCloudCredential,
                        title: String(localized: "auth_folder_path")
                    )
                }
            } header: {
                syncSettingsSectionHeader(String(localized: "adapters_next_cloud"))
            } footer: {
                Text(String(localized: "auth_folder_path_summary"))
            }

            Section {
                Button {
                    Task {
                        await testRemoteConnection()
                    }
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.syncInfo,
                        title: String(localized: "test_connection"),
                        isEnabled: !isTestingConnection
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .disabled(isTestingConnection)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "test_connection"))
                .accessibilityIdentifier("syncNextCloudTestConnectionButton")

                LabeledContent {
                    remoteStatusView
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.syncInfo,
                        title: String(localized: "status")
                    )
                }
                .accessibilityIdentifier("syncRemoteStatus")
                .accessibilityValue(remoteStatusAccessibilityValue)
            } header: {
                syncSettingsSectionHeader(String(localized: "sync_status"))
            }

            Section {
                remoteCategoryList
            } header: {
                syncSettingsSectionHeader(String(localized: "synchronization_categories"))
            }
        }
    }

    /**
     Shared Android-style remote category toggle list used by supported remote backends.
     */
    private var remoteCategoryList: some View {
        ForEach(SyncSettingsPresentation.visibleCategoryRows) { row in
            switch row {
            case .active(let category):
                activeRemoteCategoryRow(for: category)
            case .deferred(let category):
                deferredRemoteCategoryRow(for: category)
            }
        }
    }

    /**
     Builds one implemented Android-style category row with a live synchronization toggle.

     - Parameter category: Implemented remote sync category to render.
     - Returns: Row content that can enable or disable remote sync for the category.
     - Side effects:
       - tapping the row or switch mutates `remoteCategoryEnabled`
       - enabling starts the category bootstrap/synchronization flow
       - disabling persists the Android-compatible disabled state immediately
     - Failure modes:
       - synchronization failures are captured by `beginRemoteSynchronization(for:)` and surfaced
         through the row status and alert state
     */
    private func activeRemoteCategoryRow(for category: RemoteSyncCategory) -> some View {
        let categoryBinding = remoteCategoryBinding(for: category)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    categoryBinding.wrappedValue.toggle()
                } label: {
                    syncSettingsRowLabel(
                        SyncSettingsPresentation.category(category),
                        title: remoteCategoryTitle(for: category),
                        summary: remoteCategoryContentDescription(for: category),
                        detail: remoteCategorySupplementalText(for: category),
                        isEnabled: !isRemoteSyncInteractionLocked
                    )
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

    /**
     Builds one Android-visible category row whose iOS sync implementation is still deferred.

     - Parameter category: Deferred Android-visible category to disclose.
     - Returns: Disabled row content that mirrors Android ordering, title, summary, and icon.
     - Side effects: none; the row never writes `sync_enable_*` or starts synchronization.
     - Failure modes: The row cannot fail; it remains disabled until the referenced follow-up issue
       implements the category-specific sync engine.
     */
    private func deferredRemoteCategoryRow(for category: RemoteSyncDeferredCategory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            syncSettingsRowLabel(
                SyncSettingsPresentation.deferredCategory(category),
                title: deferredRemoteCategoryTitle(for: category),
                summary: deferredRemoteCategoryContentDescription(for: category),
                detail: deferredRemoteCategorySupplementalText(for: category),
                isEnabled: false
            )
            .accessibilityIdentifier("syncCategoryDeferred::\(category.rawValue)")
            .accessibilityValue("deferred")

            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
                .accessibilityIdentifier("syncCategoryDeferredSwitch::\(category.rawValue)")
                .accessibilityValue("deferred")
        }
        .disabled(true)
    }

    /**
     Builds one Android-backed sync settings row label for native SwiftUI controls.

     - Parameters:
       - row: Android sync-settings presentation row that supplies icon metadata.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - isEnabled: Whether the row should render with enabled or disabled emphasis.
     - Returns: Shared Android-shaped row label aligned with the main settings presentation.
     - Side effects: Renders an image from the module bundle when `row` has catalog metadata.
     - Failure modes: Missing icon metadata simply keeps the row aligned without an icon.
     */
    private func syncSettingsRowLabel(
        _ row: SyncSettingsPresentation.Row,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true
    ) -> AndBibleSettingsRowLabel {
        AndBibleSettingsRowLabel(
            title: title,
            summary: summary,
            detail: detail,
            icon: row.icon,
            isEnabled: isEnabled
        )
    }

    /**
     Builds an Android-shaped sync settings section header.

     - Parameter title: User-visible section title.
     - Returns: Section header aligned to the text column used by Android-backed settings rows.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func syncSettingsSectionHeader(_ title: String) -> AndBibleSettingsSectionHeader {
        AndBibleSettingsSectionHeader(title: title)
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

     - Returns: A deterministic token describing backend, enabled categories, and remote prompt state.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var syncSettingsAccessibilityValue: String {
        let enabledCategories = RemoteSyncCategory.activeSyncCases
            .filter(isRemoteCategoryEnabled)
            .map(\.rawValue)
            .sorted()
        let enabledToken = enabledCategories.isEmpty ? "none" : enabledCategories.joined(separator: ",")
        return [
            "backend=\(selectedBackend.rawValue)",
            "enabled=\(enabledToken)",
            "icloudEnabled=\(syncService.isEnabled)",
            "restartRequired=\(syncService.requiresRestart)",
            "icloudState=\(syncStateAccessibilityToken)",
            "visible=\(visibleRemoteCategoryRowsAccessibilityToken)",
            "deferred=\(deferredRemoteCategoryRowsAccessibilityToken)",
            "remoteStatus=\(remoteStatusAccessibilityValue)",
            "presentation=androidRows",
            "bootstrapPrompt=\(remoteBootstrapPromptAccessibilityToken)",
            "pendingConfirmation=\(remoteConfirmationAccessibilityToken)",
            "lastConfirmation=\(lastRemoteConfirmationAction ?? "none")",
        ]
        .joined(separator: ";")
    }

    /**
     Accessibility-exported token for the CloudKit runtime state shown in the iCloud section.

     UI smoke tests use this token to distinguish the production no-restart path from the fallback
     `.pendingRestart` state without matching localized status strings or SF Symbol names.

     - Returns: Stable state token for the current `SyncService.state`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var syncStateAccessibilityToken: String {
        switch syncService.state {
        case .disabled:
            return "disabled"
        case .noAccount:
            return "noAccount"
        case .idle:
            return "idle"
        case .syncing:
            return "syncing"
        case .pendingRestart:
            return "pendingRestart"
        case .error:
            return "error"
        }
    }

    /**
     Accessibility-exported token for the Android-runtime-visible category row order.

     - Returns: Comma-separated row identifiers in display order.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var visibleRemoteCategoryRowsAccessibilityToken: String {
        SyncSettingsPresentation.visibleCategoryRows
            .map(\.id)
            .joined(separator: ",")
    }

    /**
     Accessibility-exported token for rows shown as deferred rather than interactive.

     - Returns: Comma-separated deferred row identifiers, or `none` when no rows are deferred.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var deferredRemoteCategoryRowsAccessibilityToken: String {
        let deferredRows = SyncSettingsPresentation.visibleCategoryRows.compactMap { row -> String? in
            if case .deferred(let category) = row {
                return category.rawValue
            }
            return nil
        }
        return deferredRows.isEmpty ? "none" : deferredRows.joined(separator: ",")
    }

    /**
     Accessibility-exported token for the visible adopt-versus-create prompt.
     *
     * - Returns: `adoptOrCreate:<category>` when the first prompt is visible, otherwise `none`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private var remoteBootstrapPromptAccessibilityToken: String {
        guard let pendingRemoteAdoption else {
            return "none"
        }
        return "adoptOrCreate:\(pendingRemoteAdoption.category.rawValue)"
    }

    /**
     Accessibility-exported token for the visible destructive confirmation branch.
     *
     * - Returns: Branch and category tokens when the second confirmation is visible, otherwise `none`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private var remoteConfirmationAccessibilityToken: String {
        guard let pendingRemoteConfirmation else {
            return "none"
        }

        switch pendingRemoteConfirmation {
        case .resetLocal(let candidate):
            return "resetLocal:\(candidate.category.rawValue)"
        case .resetCloud(let candidate):
            return "resetCloud:\(candidate.category.rawValue)"
        }
    }

    /**
     UI-test-only accessibility probe used to observe the live sync-state token.

     SwiftUI's `Form` wrapper can lag behind nested state mutations when XCTest reads the
     collection view's exported value directly. This dedicated probe mirrors the same semantic
     token without changing the visible layout or exposing diagnostic tokens to real users.
     */
    @ViewBuilder
    private var syncSettingsStateProbe: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(syncSettingsAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("syncSettingsState")
                .accessibilityLabel("")
                .accessibilityValue(syncSettingsAccessibilityValue)
        }
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
     Human-readable backend name used in the backend summary footer.
     */
    private var selectedBackendTitle: String {
        switch selectedBackend {
        case .iCloud:
            return String(localized: "icloud_sync")
        case .nextCloud:
            return String(localized: "adapters_next_cloud")
        }
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

        if UITestRuntimeConfiguration.remoteSyncBootstrapScenario == .adoptExisting {
            selectedBackend = .nextCloud
            serverURL = "https://example.invalid/remote.php/dav/files/ui-test"
            lastCommittedServerURL = serverURL
            username = "ui-test"
            password = "ui-test"
            folderPath = ""
            remoteCategoryEnabled = Dictionary(
                uniqueKeysWithValues: RemoteSyncCategory.activeSyncCases.map { category in
                    (category, false)
                }
            )
            hasLoadedSettings = true
            return
        }

        selectedBackend = remoteSettingsStore.selectedBackend

        if let configuration = remoteSettingsStore.loadWebDAVConfiguration() {
            serverURL = configuration.serverURL
            lastCommittedServerURL = configuration.serverURL
            username = configuration.username
            folderPath = configuration.folderPath ?? ""
        } else {
            lastCommittedServerURL = serverURL
        }
        password = remoteSettingsStore.webDAVPassword() ?? ""
        remoteCategoryEnabled = Dictionary(
            uniqueKeysWithValues: RemoteSyncCategory.activeSyncCases.map { category in
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
        guard isAndroidValidNextCloudServerURL(serverURL) else {
            return
        }
        try? store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: serverURL,
                username: username,
                folderPath: normalizedFolderPath
            ),
            password: password
        )
        lastCommittedServerURL = serverURL
    }

    /**
     Applies Android's server URL edit-validation behavior to the inline iOS field.

     Android validates `cloud_sync_server_url` from `serverUrlPref.setOnPreferenceChangeListener`
     and rejects malformed edits before they are written to preferences. iOS uses an inline
     `TextField`, so submit and focus-loss events call this method as the equivalent commit boundary.

     - Returns: `true` when the edit was accepted and persisted, otherwise `false`.
     - Side effects:
     - invalid URLs update the transient remote status and present the same localized error dialog
     - valid URLs clear stale connection-test status and persist the current remote settings

     Failure modes:
     - local persistence failures are still swallowed by `persistRemoteSettings()`, matching the
       existing settings-save behavior
     */
    @discardableResult
    private func validateNextCloudServerURLAfterEditing() -> Bool {
        guard selectedBackend == .nextCloud else {
            return true
        }

        let invalidURLMessage = String(localized: "invalid_url_message")
        if serverURL == lastCommittedServerURL,
           remoteConnectionStatus == .failure(invalidURLMessage)
        {
            return false
        }
        guard isAndroidValidNextCloudServerURL(serverURL) else {
            remoteConnectionStatus = .failure(invalidURLMessage)
            remoteSyncErrorMessage = invalidURLMessage
            serverURL = lastCommittedServerURL
            return false
        }

        remoteConnectionStatus = nil
        persistRemoteSettings()
        return true
    }

    /**
     Checks the NextCloud server URL with the same structural rules Android applies before saving.

     Android requires a syntactically valid HTTP(S) URL, rejects whitespace, and prevents users from
     saving a `/login` page URL instead of the server root. Username and password are intentionally
     not part of this check because Android validates the server preference independently.

     - Parameter candidate: User-entered server URL.
     - Returns: `true` when the URL may be saved to WebDAV settings.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func isAndroidValidNextCloudServerURL(_ candidate: String) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else {
            return false
        }
        guard trimmedCandidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }
        guard let components = URLComponents(string: trimmedCandidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return false
        }
        return !trimmedCandidate.hasSuffix("/login")
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
       - may perform remote bootstrap validation, initial-backup restore, or sparse patch sync
       - may present adopt-versus-create alerts by mutating view state
     - Failure modes:
       - invalid or incomplete backend configuration disables the category again and surfaces an error
       - transport or synchronization failures leave the category enabled to match Android's retry semantics, while surfacing the latest error
     */
    @MainActor
    private func beginRemoteSynchronization(for category: RemoteSyncCategory) async {
        persistRemoteSettings()
        lastRemoteConfirmationAction = nil

        do {
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
            let completedAction: String

            switch confirmation {
            case .resetLocal(let candidate):
                report = try await service.adoptRemoteFolderAndSynchronize(
                    for: candidate.category,
                    remoteFolderID: candidate.remoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
                completedAction = "resetLocal"
            case .resetCloud(let candidate):
                report = try await service.createRemoteFolderAndSynchronize(
                    for: candidate.category,
                    replacingRemoteFolderID: candidate.remoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
                completedAction = "resetCloud"
            }

            remoteCategoryStatuses[category] = .idle
            finishRemoteSynchronization(with: report, for: category)
            lastRemoteConfirmationAction = "\(completedAction):\(category.rawValue)"
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
        lastRemoteConfirmationAction = nil
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
         required local configuration
       - throws `WebDAVClientError.invalidURL` when the stored NextCloud server URL cannot be normalized
     */
    private func makeRemoteSynchronizationService() throws -> RemoteSyncSynchronizationService {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.andbible.ios"
        if UITestRuntimeConfiguration.remoteSyncBootstrapScenario == .adoptExisting {
            return RemoteSyncSynchronizationService(
                adapter: UITestRemoteSyncAdapter(bundleIdentifier: bundleIdentifier),
                bundleIdentifier: bundleIdentifier,
                deviceIdentifier: remoteSettingsStore.deviceIdentifier(),
                nowProvider: { 1_735_689_900_000 }
            )
        }

        let factory = RemoteSyncSynchronizationServiceFactory(bundleIdentifier: bundleIdentifier)
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
        RemoteSyncCategoryLocalization.text(for: category).title.localized
    }

    /**
     Returns Android's category description string for the supplied sync category.

     - Parameter category: Logical sync category to describe.
     - Returns: Localized Android-aligned category description.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func remoteCategoryContentDescription(for category: RemoteSyncCategory) -> String {
        RemoteSyncCategoryLocalization.text(for: category).contents.localized
    }

    /**
     Returns the Android title string for a deferred category row.

     - Parameter category: Deferred category to label.
     - Returns: Localized title matching Android's visible sync setting where available.
     - Side effects: none.
     - Failure modes: Missing localizations fall back to English defaults.
     */
    private func deferredRemoteCategoryTitle(for category: RemoteSyncDeferredCategory) -> String {
        RemoteSyncCategoryLocalization.deferredText(for: category).title.localized
    }

    /**
     Returns the Android summary string for a deferred category row.

     - Parameter category: Deferred category to describe.
     - Returns: Localized summary matching Android's sync setting where available.
     - Side effects: none.
     - Failure modes: Missing localizations fall back to English defaults.
     */
    private func deferredRemoteCategoryContentDescription(for category: RemoteSyncDeferredCategory) -> String {
        RemoteSyncCategoryLocalization.deferredText(for: category).contents.localized
    }

    /**
     Returns the explicit deferred-state caption for an Android-visible row without iOS sync support.

     - Parameter category: Deferred category whose follow-up issue should be named.
     - Returns: Human-readable caption that explains why the row is disabled.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func deferredRemoteCategorySupplementalText(for category: RemoteSyncDeferredCategory) -> String {
        String(
            format: String(localized: "sync_category_deferred_issue", defaultValue: "Sync support is deferred (#%d)."),
            category.trackingIssueNumber
        )
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
