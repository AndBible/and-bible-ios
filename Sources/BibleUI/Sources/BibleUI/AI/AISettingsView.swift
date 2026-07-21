// AISettingsView.swift -- Production AI settings entry point and quick setup

import BibleCore
import SwiftData
import SwiftUI
import SwordKit

/** Production entry point for Android-compatible AI settings. */
public struct AISettingsView: View {
    /// App SwiftData context containing synced AI settings and local raw logs.
    @Environment(\.modelContext) private var modelContext

    /// Optional installed-module manager used to discover add-on prompt packs.
    private let swordManager: SwordManager?
    /// Device-only credential boundary; never copied into SwiftUI state by this screen.
    private let credentialStore: AICredentialStore

    /**
     Creates the AI settings destination.

     - Parameters:
       - swordManager: Optional installed-module source for read-only prompt packs.
       - credentialStore: Device-only Keychain facade.
     - Side effects: None until the view appears and loads settings.
     - Failure modes: Persistence and Keychain failures are surfaced as native alerts.
     */
    public init(
        swordManager: SwordManager? = nil,
        credentialStore: AICredentialStore = .keychain()
    ) {
        self.swordManager = swordManager
        self.credentialStore = credentialStore
    }

    public var body: some View {
        AISettingsContentView(
            modelContext: modelContext,
            swordManager: swordManager,
            credentialStore: credentialStore
        )
    }
}

/** Secret-free provider row state rendered by the top-level AI settings screen. */
private struct AIProviderRowState: Identifiable {
    /// Provider configuration identity.
    let id: UUID
    /// User-visible provider name.
    let name: String
    /// Configured model count.
    let modelCount: Int
    /// Whether a device-only credential exists.
    let hasCredential: Bool
    /// Whether this row meets every execution prerequisite.
    let isUsable: Bool
}

/** Operational AI settings content bound to one model context. */
private struct AISettingsContentView: View {
    @Environment(\.dismiss) private var dismiss

    let modelContext: ModelContext
    let swordManager: SwordManager?
    let credentialStore: AICredentialStore

    @State private var revision = 0
    @State private var showingQuickSetup = false
    @State private var showingResetConfirmation = false
    @State private var showingDisclaimer = false
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }

    private var providers: [AIProviderRowState] {
        guard let rows = try? settingsStore.providers() else { return [] }
        return rows.map { provider in
            let modelIDs = Set((try? settingsStore.models(providerConfigId: provider.id))?.map(\.id) ?? [])
            let snapshot = AIProviderUsabilitySnapshot(
                providerID: provider.id,
                hasCredential: credentialStore.credential(for: provider.id) != nil,
                modelIDs: modelIDs
            )
            return AIProviderRowState(
                id: provider.id,
                name: provider.displayName,
                modelCount: modelIDs.count,
                hasCredential: snapshot.hasCredential,
                isUsable: AIConfigurationUsability.providerIsUsable(snapshot)
            )
        }
    }

    private var isReady: Bool {
        guard let settings = try? settingsStore.globalSettings() else { return false }
        let snapshots = providers.map { row in
            AIProviderUsabilitySnapshot(
                providerID: row.id,
                hasCredential: row.hasCredential,
                modelIDs: Set((try? settingsStore.models(providerConfigId: row.id))?.map(\.id) ?? [])
            )
        }
        return AIConfigurationUsability.defaultModelIsUsable(
            defaultModelID: settings.defaultModelId,
            providers: snapshots
        )
    }

    var body: some View {
        Form {
            if !isReady {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(String(localized: "ai_setup_title", defaultValue: "Configure AI"))
                                .font(.headline)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        Text(
                            String(
                                localized: "ai_setup_description",
                                defaultValue: "AndBible can use AI to translate Bible text, explain verses, create summaries, and more. To get started, configure a connection to an OpenAI-compatible API provider."
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Button {
                            showingQuickSetup = true
                        } label: {
                            Label(
                                String(localized: "easy_setup_title", defaultValue: "Quick Setup"),
                                systemImage: "wand.and.stars"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("aiQuickSetupButton")
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(String(localized: "ai_providers_models_category", defaultValue: "Providers & Models")) {
                if providers.isEmpty {
                    Text(String(localized: "ai_providers_summary_none", defaultValue: "No providers configured"))
                        .foregroundStyle(.secondary)
                }
                ForEach(providers) { provider in
                    NavigationLink {
                        AIProviderSettingsView(
                            providerID: provider.id,
                            credentialStore: credentialStore,
                            onChanged: refresh
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider.isUsable ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                .foregroundStyle(provider.isUsable ? Color.green : Color.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.name)
                                if !provider.hasCredential {
                                    Text(String(localized: "ai_provider_api_key_not_set", defaultValue: "API key not set"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(
                                        provider.modelCount == 0
                                            ? String(localized: "ai_models_summary_none", defaultValue: "No models configured")
                                            : "\(provider.modelCount)"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                NavigationLink {
                    AIProviderSettingsView(
                        providerID: nil,
                        credentialStore: credentialStore,
                        onChanged: refresh
                    )
                } label: {
                    Label(
                        String(localized: "ai_add_provider", defaultValue: "Add provider"),
                        systemImage: "plus"
                    )
                }
                .accessibilityIdentifier("aiAddProviderLink")
            }

            Section {
                NavigationLink {
                    AIPromptManagementView(swordManager: swordManager)
                } label: {
                    Label(
                        String(localized: "manage_prompts", defaultValue: "Manage AI Prompts"),
                        systemImage: "text.bubble"
                    )
                }
                NavigationLink {
                    AIPermissionSettingsView(swordManager: swordManager)
                } label: {
                    Label(
                        String(localized: "prompt_tool_permissions", defaultValue: "Tool permissions"),
                        systemImage: "checkmark.shield"
                    )
                }
                NavigationLink {
                    AIUsageAndLogsView()
                } label: {
                    Label(
                        String(localized: "ai_usage_category", defaultValue: "Usage"),
                        systemImage: "chart.bar.xaxis"
                    )
                }
            }

            Section(String(localized: "ai_behavior_category", defaultValue: "Behavior")) {
                NavigationLink {
                    AIBehaviorSettingsView()
                } label: {
                    Label(
                        String(localized: "ai_behavior_category", defaultValue: "Behavior"),
                        systemImage: "slider.horizontal.3"
                    )
                }
                Button {
                    showingDisclaimer = true
                } label: {
                    Label(
                        String(
                            localized: "ai_disclaimer_warning_title",
                            defaultValue: "Important: Read before using AI tools"
                        ),
                        systemImage: "info.circle"
                    )
                }
            }

            Section {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label(
                        String(localized: "reset_all_ai_settings", defaultValue: "Reset all AI settings"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .accessibilityIdentifier("aiResetButton")
            }
        }
        .id(revision)
        .navigationTitle(String(localized: "ai_settings", defaultValue: "AI Settings"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showingQuickSetup, onDismiss: refresh) {
            NavigationStack {
                AIQuickSetupView(credentialStore: credentialStore, onSaved: {
                    showingQuickSetup = false
                    refresh()
                })
            }
        }
        .sheet(isPresented: $showingDisclaimer) {
            NavigationStack { AIDisclaimerView() }
        }
        .alert(
            String(localized: "reset_all_ai_settings_confirm_title", defaultValue: "Reset all AI settings?"),
            isPresented: $showingResetConfirmation
        ) {
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(
                String(localized: "reset_all_ai_settings", defaultValue: "Reset all AI settings"),
                role: .destructive
            ) {
                resetAISettings()
            }
        } message: {
            Text(
                String(
                    localized: "reset_all_ai_settings_confirm_message",
                    defaultValue: "This will clear the API key, provider, endpoint, model, and reset all prompts to defaults. Continue?"
                )
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

    /** Forces a fresh secret-free settings snapshot after a child mutation. */
    private func refresh() {
        revision &+= 1
    }

    /** Applies Android reset semantics while preserving local raw-log history. */
    private func resetAISettings() {
        do {
            try AISettingsResetter.reset(
                settingsStore: settingsStore,
                credentialStore: credentialStore
            )
            refresh()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Three-step-equivalent quick setup presented as one compact operational form. */
private struct AIQuickSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let credentialStore: AICredentialStore
    let onSaved: () -> Void

    @State private var selectedProvider = LLMProvider.gemini
    @State private var apiKey = ""
    @State private var testing = false
    @State private var statusMessage: String?
    @State private var testSucceeded = false

    private var option: AIRecommendedSetup {
        AIRecommendedSetupCatalog.options.first { $0.provider == selectedProvider }
            ?? AIRecommendedSetupCatalog.options[0]
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "model_select_provider", defaultValue: "Provider"), selection: $selectedProvider) {
                    ForEach(AIRecommendedSetupCatalog.options) { setup in
                        Text(AIProviderPresentation.displayName(for: setup.provider)).tag(setup.provider)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text(String(localized: "easy_setup_title", defaultValue: "Quick Setup"))
            }

            Section {
                LabeledContent(
                    String(localized: "llm_openrouter_model", defaultValue: "Model"),
                    value: option.modelID
                )
                SecureField(
                    String(localized: "easy_setup_enter_api_key", defaultValue: "Enter your API key"),
                    text: $apiKey
                )
                .textContentType(.password)
                Button {
                    testConnection()
                } label: {
                    Label(
                        testing
                            ? String(localized: "easy_setup_testing", defaultValue: "Testing…")
                            : String(localized: "easy_setup_test_connection", defaultValue: "Test connection"),
                        systemImage: "network"
                    )
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)

                if let statusMessage {
                    Label(statusMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSucceeded ? Color.green : Color.red)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    saveSetup()
                } label: {
                    Label(String(localized: "save", defaultValue: "Save"), systemImage: "checkmark")
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                .accessibilityIdentifier("aiQuickSetupSaveButton")
            }
        }
        .navigationTitle(String(localized: "easy_setup_title", defaultValue: "Quick Setup"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel", defaultValue: "Cancel")) { dismiss() }
            }
        }
        .onChange(of: selectedProvider) {
            statusMessage = nil
            testSucceeded = false
        }
    }

    /** Tests the transient key without inserting a provider, model, or secret. */
    private func testConnection() {
        let transient = ResolvedLLMModel(
            configuredModelId: UUID(),
            providerConfigId: UUID(),
            modelId: option.modelID,
            apiFormat: option.provider.apiFormat,
            endpoint: option.provider.endpoint!,
            credential: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            supportsCacheControl: option.provider.supportsCacheControl
        )
        testing = true
        statusMessage = nil
        Task {
            do {
                _ = try await AIConnectionTester().test(model: transient)
                await MainActor.run {
                    testing = false
                    testSucceeded = true
                    statusMessage = String(localized: "easy_setup_success", defaultValue: "Connection successful!")
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testSucceeded = false
                    statusMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
                }
            }
        }
    }

    /** Inserts Android's exact provider/model/default tuple and stores the key only in Keychain. */
    private func saveSetup() {
        let store = AISettingsStore(modelContext: modelContext)
        let provider = LLMProviderConfig(
            provider: option.provider,
            displayName: AIProviderPresentation.displayName(for: option.provider),
            orderNumber: (try? store.providers().count) ?? 0
        )
        let model = LLMConfiguredModel(
            providerConfigId: provider.id,
            modelId: option.modelID,
            inputPricePerMillion: option.inputPricePerMillion,
            outputPricePerMillion: option.outputPricePerMillion,
            cacheCreationPricePerMillion: option.cacheCreationPricePerMillion,
            cacheReadPricePerMillion: option.cacheReadPricePerMillion
        )
        do {
            try store.insertProvider(provider)
            do {
                try credentialStore.setCredential(
                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    for: provider.id
                )
                try store.insertModel(model)
                let settings = try store.globalSettings()
                settings.defaultModelId = model.id
                settings.aiDisclaimerAccepted = true
                try store.save()
                apiKey = ""
                onSaved()
            } catch {
                try? credentialStore.removeCredential(for: provider.id)
                try? store.deleteProvider(id: provider.id)
                throw error
            }
        } catch {
            statusMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
            testSucceeded = false
        }
    }
}

/** Native presentation of Android's AI responsibility notice. */
private struct AIDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "ai_disclaimer_intro",
                        defaultValue: "AI tools can greatly enrich your Bible study experience and open new ways to engage with Scripture."
                    )
                )
                Text(
                    String(
                        localized: "ai_disclaimer_approach",
                        defaultValue: "AndBible primarily uses AI to process text from the documents you have installed — commentaries, dictionaries, and other modules — rather than relying on the model's own training data."
                    )
                )
                Text(
                    String(
                        localized: "ai_disclaimer_responsibility",
                        defaultValue: "However, they are still powerful tools — and with great power comes great responsibility. Please bear the following in mind."
                    )
                )
                    .font(.headline)
                ForEach(1...9, id: \.self) { index in
                    let key = String.LocalizationValue("ai_disclaimer_point\(index)")
                    Text(verbatim: "• " + String(localized: key))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(String(localized: "ai_disclaimer_dialog_title", defaultValue: "AI Tools — Important Information"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done", defaultValue: "Done")) { dismiss() }
            }
        }
    }
}
