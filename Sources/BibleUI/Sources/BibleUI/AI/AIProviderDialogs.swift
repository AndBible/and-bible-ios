// AIProviderDialogs.swift -- Android provider configuration dialogs

import BibleCore
import SwiftData
import SwiftUI

/** Android's Add/Edit provider AlertDialog over the Providers screen. */
struct AIProviderSettingsDialog: View {
    /// SwiftData context containing non-secret provider rows.
    @Environment(\.modelContext) private var modelContext

    /// Existing provider identity, or `nil` for creation.
    let providerID: UUID?
    /// Provider type selected by Android's preceding chooser.
    let initialProviderType: LLMProvider
    /// Device-local Keychain boundary.
    let credentialStore: AICredentialStore
    /// Negative action callback.
    let onCancel: () -> Void
    /// Successful save callback.
    let onSaved: () -> Void
    /// Existing-provider delete transition callback.
    let onRequestDelete: (UUID, String) -> Void

    /// Fixed known provider type, or Custom for editable endpoint settings.
    @State private var providerType: LLMProvider
    /// User-visible provider name.
    @State private var displayName: String
    /// Visible-password credential field, matching Android's provider dialog.
    @State private var credentialDraft = ""
    /// Custom base endpoint.
    @State private var endpoint = ""
    /// Custom provider wire format.
    @State private var apiFormat = APIFormat.openAI
    /// Credential-free persistence or Keychain failure text.
    @State private var failureMessage: String?

    /**
     Creates a provider dialog for an existing row or one selected provider type.

     - Parameters:
       - providerID: Existing provider identity, or `nil` for creation.
       - initialProviderType: Type selected before opening a new-provider dialog.
       - credentialStore: Device-local Keychain facade.
       - onCancel: Callback that closes the dialog without mutation.
       - onSaved: Callback after both provider and credential commit.
       - onRequestDelete: Callback that replaces editing with deletion confirmation.
     - Side effects: Existing dialogs load their local credential into transient view state, as
       Android does with a visible-password field; the value is cleared on disappearance.
     - Failure modes: Missing rows retain initialized defaults; save failures remain in the dialog.
     */
    init(
        providerID: UUID?,
        initialProviderType: LLMProvider,
        credentialStore: AICredentialStore,
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onRequestDelete: @escaping (UUID, String) -> Void
    ) {
        self.providerID = providerID
        self.initialProviderType = initialProviderType
        self.credentialStore = credentialStore
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onRequestDelete = onRequestDelete
        _providerType = State(initialValue: initialProviderType)
        _displayName = State(
            initialValue: providerID == nil && initialProviderType != .custom
                ? AIProviderPresentation.displayName(for: initialProviderType)
                : ""
        )
    }

    /// SwiftData facade for provider mutations.
    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    /// Whether the current dialog creates a provider.
    private var isNewProvider: Bool { providerID == nil }
    /// Whitespace-trimmed API key used for Keychain writes.
    private var trimmedCredential: String {
        credentialDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        AIAndroidDialogSurface(
            title: isNewProvider
                ? String(localized: "ai_add_provider", defaultValue: "Add provider")
                : String(localized: "ai_provider_edit", defaultValue: "Edit")
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    labeledField(String(localized: "ai_provider_name", defaultValue: "Provider name")) {
                        TextField(
                            String(localized: "ai_provider_name", defaultValue: "Provider name"),
                            text: $displayName
                        )
                        .disabled(providerType != .custom)
                    }

                    labeledField(String(localized: "ai_provider_api_key", defaultValue: "API key")) {
                        TextField(
                            String(localized: "ai_provider_api_key", defaultValue: "API key"),
                            text: $credentialDraft
                        )
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("aiProviderAPIKeyField")
                    }

                    if let apiKeyURL {
                        Link(
                            "\(String(localized: "easy_setup_api_key_instructions", defaultValue: "Get your API key from:")) \(AIProviderPresentation.displayName(for: providerType))",
                            destination: apiKeyURL
                        )
                        .padding(.vertical, 4)
                    }

                    if providerType == .custom {
                        labeledField(String(localized: "ai_provider_endpoint", defaultValue: "API endpoint")) {
                            TextField(
                                String(localized: "ai_provider_endpoint", defaultValue: "API endpoint"),
                                text: $endpoint
                            )
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .autocorrectionDisabled()
                        }

                        Text(
                            String(
                                localized: "ai_provider_endpoint_description",
                                defaultValue: "Base URL only. AndBible appends \"/chat/completions\" (OpenAI format) or \"/messages\" (Anthropic format) automatically. Model lists are fetched from \"/models\"."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        labeledField(String(localized: "ai_provider_api_format", defaultValue: "API format")) {
                            Picker(
                                String(localized: "ai_provider_api_format", defaultValue: "API format"),
                                selection: $apiFormat
                            ) {
                                Text(verbatim: "OPENAI").tag(APIFormat.openAI)
                                Text(verbatim: "ANTHROPIC").tag(APIFormat.anthropic)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 520)
        } actions: {
            if let providerID {
                AIAndroidDialogAction(
                    title: String(localized: "delete", defaultValue: "Delete"),
                    isDestructive: true,
                    action: { onRequestDelete(providerID, resolvedDisplayName) }
                )
                .accessibilityIdentifier("aiProviderDeleteButton")
            }
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiProviderCancelButton")
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                isEnabled: !trimmedCredential.isEmpty,
                action: saveProvider
            )
            .accessibilityIdentifier("aiProviderSaveButton")
        }
        .accessibilityIdentifier("aiProviderEditorScreen")
        .task(id: providerID) { loadProvider() }
        .onDisappear { credentialDraft = "" }
        .alert(
            String(localized: "error", defaultValue: "Error"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK")) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /// Android's blank-name fallback for Custom and defensive malformed existing rows.
    private var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AIProviderPresentation.displayName(for: providerType) : trimmed
    }

    /// Android's provider-specific API-key destination for known provider types.
    private var apiKeyURL: URL? {
        let rawURL: String
        switch providerType {
        case .gemini: rawURL = "https://aistudio.google.com/apikey"
        case .openAI: rawURL = "https://platform.openai.com/api-keys"
        case .anthropic: rawURL = "https://console.anthropic.com/settings/keys"
        case .xAI: rawURL = "https://console.x.ai/"
        case .mistral: rawURL = "https://console.mistral.ai/api-keys"
        case .deepSeek: rawURL = "https://platform.deepseek.com/api_keys"
        case .groq: rawURL = "https://console.groq.com/keys"
        case .alibaba: rawURL = "https://bailian.console.alibabacloud.com/?apiKey=1#/api-key"
        case .openRouter: rawURL = "https://openrouter.ai/keys"
        case .custom: return nil
        }
        return URL(string: rawURL)
    }

    /** Builds one Android-style labeled underline field. */
    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    /**
     Loads Android's editable provider fields, including its visible-password API key.

     - Side effects: Reads SwiftData and copies the local Keychain value into transient view state.
     - Failure modes: Missing rows leave initialized values unchanged.
     */
    private func loadProvider() {
        guard let providerID,
              let provider = try? settingsStore.provider(id: providerID) else { return }
        providerType = provider.provider
        displayName = provider.displayName
        endpoint = provider.endpoint ?? ""
        apiFormat = provider.apiFormat
        credentialDraft = credentialStore.credential(for: providerID) ?? ""
    }

    /**
     Saves provider metadata and its required device-local credential.

     - Side effects: Inserts or updates SwiftData, writes Keychain, starts a best-effort sanitized
       dynamic-model cache refresh when Android supports it, clears transient credential state, and
       invokes `onSaved` after both stores commit.
     - Failure modes: New-provider Keychain failure removes the staged SwiftData row; all failures
       leave this dialog visible with credential-free error copy.
     */
    private func saveProvider() {
        guard !trimmedCredential.isEmpty else { return }
        do {
            let savedProvider: LLMProviderConfig
            if let providerID,
               let provider = try settingsStore.provider(id: providerID) {
                provider.displayName = resolvedDisplayName
                if providerType == .custom {
                    provider.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    provider.apiFormatRawValue = apiFormat.rawValue
                }
                try credentialStore.setCredential(trimmedCredential, for: providerID)
                try settingsStore.save()
                savedProvider = provider
            } else {
                let provider = LLMProviderConfig(
                    provider: providerType,
                    displayName: resolvedDisplayName,
                    endpoint: providerType == .custom
                        ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil,
                    apiFormat: providerType == .custom ? apiFormat : nil,
                    orderNumber: (try? settingsStore.providers().count) ?? 0
                )
                try settingsStore.insertProvider(provider)
                do {
                    try credentialStore.setCredential(trimmedCredential, for: provider.id)
                } catch {
                    try? settingsStore.deleteProvider(id: provider.id)
                    throw error
                }
                savedProvider = provider
            }
            let refreshProvider = savedProvider.provider
            let refreshEndpoint = savedProvider.resolvedEndpoint
            let refreshCredential = trimmedCredential
            if let refreshEndpoint,
               AIModelCatalog.supportsDynamicModels(refreshProvider) {
                Task {
                    await AIDynamicModelService.shared.refreshIfNeeded(
                        provider: refreshProvider,
                        endpoint: refreshEndpoint,
                        credential: refreshCredential
                    )
                }
            }
            credentialDraft = ""
            onSaved()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Android's provider deletion confirmation shown after the edit dialog closes. */
struct AIProviderDeleteConfirmationDialog: View {
    /// SwiftData context containing provider and dependent model rows.
    @Environment(\.modelContext) private var modelContext

    /// Provider identity to delete.
    let providerID: UUID
    /// Provider name interpolated into Android's warning.
    let displayName: String
    /// Device-local credential boundary.
    let credentialStore: AICredentialStore
    /// Android's No action.
    let onCancel: () -> Void
    /// Callback after provider graph deletion commits.
    let onDeleted: () -> Void

    /// Credential-free deletion failure text.
    @State private var failureMessage: String?

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "delete", defaultValue: "Delete")
        ) {
            Text(
                String(
                    format: String(
                        localized: "ai_provider_delete_confirm",
                        defaultValue: "Delete provider \"%1$@\"? Prompts using this provider will revert to the default."
                    ),
                    displayName
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "no", defaultValue: "No"),
                action: onCancel
            )
            AIAndroidDialogAction(
                title: String(localized: "yes", defaultValue: "Yes"),
                isDestructive: true,
                action: deleteProvider
            )
        }
        .alert(
            String(localized: "error", defaultValue: "Error"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK")) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /** Deletes the local credential before the synced provider graph. */
    private func deleteProvider() {
        do {
            try credentialStore.removeCredential(for: providerID)
            try AISettingsStore(modelContext: modelContext).deleteProvider(id: providerID)
            onDeleted()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}
