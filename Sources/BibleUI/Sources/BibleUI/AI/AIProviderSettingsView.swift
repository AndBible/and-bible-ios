// AIProviderSettingsView.swift -- Provider, credential, model, and connection management

import BibleCore
import SwiftData
import SwiftUI

/** Native provider editor with model CRUD and device-only credential actions. */
struct AIProviderSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let credentialStore: AICredentialStore
    private let onChanged: () -> Void

    @State private var savedProviderID: UUID?
    @State private var providerType = LLMProvider.gemini
    @State private var displayName = ""
    @State private var endpoint = ""
    @State private var apiFormat = APIFormat.openAI
    @State private var credentialDraft = ""
    @State private var hasCredential = false
    @State private var showingModelEditor = false
    @State private var editingModelID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var testing = false
    @State private var statusMessage: String?
    @State private var statusSucceeded = false
    @State private var revision = 0

    /** Creates an editor for an existing provider or a new unsaved row. */
    init(
        providerID: UUID?,
        credentialStore: AICredentialStore,
        onChanged: @escaping () -> Void
    ) {
        _savedProviderID = State(initialValue: providerID)
        self.credentialStore = credentialStore
        self.onChanged = onChanged
    }

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }

    private var models: [LLMConfiguredModel] {
        guard let savedProviderID else { return [] }
        return (try? settingsStore.models(providerConfigId: savedProviderID)) ?? []
    }

    private var defaultModelID: UUID? {
        try? settingsStore.globalSettings().defaultModelId
    }

    var body: some View {
        Form {
            Section(String(localized: "ai_connection_settings", defaultValue: "Connection settings")) {
                Picker(
                    String(localized: "ai_provider_select_type", defaultValue: "Select provider type"),
                    selection: $providerType
                ) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(AIProviderPresentation.displayName(for: provider)).tag(provider)
                    }
                }
                TextField(
                    String(localized: "ai_provider_name", defaultValue: "Provider name"),
                    text: $displayName
                )
                if providerType == .custom {
                    TextField(
                        String(localized: "ai_provider_endpoint", defaultValue: "API endpoint"),
                        text: $endpoint
                    )
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    Picker(
                        String(localized: "ai_provider_api_format", defaultValue: "API format"),
                        selection: $apiFormat
                    ) {
                        Text(verbatim: "OpenAI").tag(APIFormat.openAI)
                        Text(verbatim: "Anthropic").tag(APIFormat.anthropic)
                    }
                    Text(
                        String(
                            localized: "ai_provider_endpoint_description",
                            defaultValue: "Base URL only. AndBible appends \"/chat/completions\" (OpenAI format) or \"/messages\" (Anthropic format) automatically. Model lists are fetched from \"/models\"."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button {
                    saveProvider()
                } label: {
                    Label(String(localized: "save_and_exit", defaultValue: "Save"), systemImage: "checkmark")
                }
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("aiProviderSaveButton")
            }

            Section(String(localized: "ai_provider_api_key", defaultValue: "API key")) {
                if hasCredential {
                    Label(
                        String(localized: "ai_provider_api_key", defaultValue: "API key"),
                        systemImage: "key.fill"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        String(localized: "ai_provider_api_key_not_set", defaultValue: "API key not set"),
                        systemImage: "key"
                    )
                    .foregroundStyle(.orange)
                }
                SecureField(
                    String(localized: "ai_provider_api_key", defaultValue: "API key"),
                    text: $credentialDraft
                )
                .textContentType(.password)
                HStack {
                    Button {
                        saveCredential()
                    } label: {
                        Label(
                            String(localized: "save_and_exit", defaultValue: "Save"),
                            systemImage: "key"
                        )
                    }
                    .disabled(savedProviderID == nil || credentialDraft.isEmpty)
                    Spacer()
                    if hasCredential {
                        Button(role: .destructive) {
                            deleteCredential()
                        } label: {
                            Label(String(localized: "delete", defaultValue: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }

            Section(String(localized: "ai_models_category", defaultValue: "Models")) {
                if models.isEmpty {
                    Text(String(localized: "ai_models_summary_none", defaultValue: "No models configured"))
                        .foregroundStyle(.secondary)
                }
                ForEach(models) { model in
                    HStack(spacing: 10) {
                        Button {
                            setDefaultModel(model.id)
                        } label: {
                            Image(systemName: defaultModelID == model.id ? "star.fill" : "star")
                                .foregroundStyle(defaultModelID == model.id ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            String(localized: "model_set_default", defaultValue: "Set as default model")
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.modelId)
                            Text(
                                String(
                                    format: String(
                                        localized: "model_pricing_summary",
                                        defaultValue: "%1$@ in / %2$@ out per Mtoken"
                                    ),
                                    model.inputPricePerMillion.formatted(.currency(code: "USD")),
                                    model.outputPricePerMillion.formatted(.currency(code: "USD"))
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button {
                                editingModelID = model.id
                                showingModelEditor = true
                            } label: {
                                Label(String(localized: "ai_provider_edit", defaultValue: "Edit"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteModel(model.id)
                            } label: {
                                Label(String(localized: "delete", defaultValue: "Delete"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                Button {
                    editingModelID = nil
                    showingModelEditor = true
                } label: {
                    Label(String(localized: "add_model", defaultValue: "Add model"), systemImage: "plus")
                }
                .disabled(savedProviderID == nil)

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
                .disabled(!hasCredential || models.isEmpty || testing)

                if let statusMessage {
                    Label(statusMessage, systemImage: statusSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(statusSucceeded ? Color.green : Color.red)
                        .font(.subheadline)
                }
            }

            if savedProviderID != nil {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label(String(localized: "delete", defaultValue: "Delete"), systemImage: "trash")
                    }
                }
            }
        }
        .id(revision)
        .navigationTitle(
            savedProviderID == nil
                ? String(localized: "ai_add_provider", defaultValue: "Add provider")
                : displayName
        )
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: savedProviderID) { loadProvider() }
        .onChange(of: providerType) {
            if savedProviderID == nil || displayName.isEmpty {
                displayName = AIProviderPresentation.displayName(for: providerType)
            }
            if providerType != .custom {
                apiFormat = providerType.apiFormat
            }
        }
        .onDisappear { credentialDraft = "" }
        .sheet(isPresented: $showingModelEditor, onDismiss: refresh) {
            NavigationStack {
                if let savedProviderID {
                    AIModelEditorView(
                        providerID: savedProviderID,
                        modelID: editingModelID,
                        onSaved: {
                            showingModelEditor = false
                            refresh()
                        }
                    )
                }
            }
        }
        .alert(
            String(localized: "delete", defaultValue: "Delete"),
            isPresented: $showingDeleteConfirmation
        ) {
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                deleteProvider()
            }
        } message: {
            Text(
                String(
                    format: String(
                        localized: "ai_provider_delete_confirm",
                        defaultValue: "Delete provider \"%1$@\"? Prompts using this provider will revert to the default."
                    ),
                    displayName
                )
            )
        }
    }

    /** Loads non-secret provider fields and credential presence. */
    private func loadProvider() {
        guard let savedProviderID,
              let provider = try? settingsStore.provider(id: savedProviderID) else {
            displayName = AIProviderPresentation.displayName(for: providerType)
            hasCredential = false
            return
        }
        providerType = provider.provider
        displayName = provider.displayName
        endpoint = provider.endpoint ?? ""
        apiFormat = provider.apiFormat
        hasCredential = credentialStore.credential(for: savedProviderID) != nil
    }

    /** Inserts or updates only non-secret provider configuration. */
    private func saveProvider() {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        do {
            if let savedProviderID,
               let provider = try settingsStore.provider(id: savedProviderID) {
                provider.providerType = providerType.rawValue
                provider.displayName = trimmedName
                provider.endpoint = providerType == .custom ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                provider.apiFormatRawValue = providerType == .custom ? apiFormat.rawValue : nil
                try settingsStore.save()
            } else {
                let provider = LLMProviderConfig(
                    provider: providerType,
                    displayName: trimmedName,
                    endpoint: providerType == .custom ? endpoint.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    apiFormat: providerType == .custom ? apiFormat : nil,
                    orderNumber: (try? settingsStore.providers().count) ?? 0
                )
                try settingsStore.insertProvider(provider)
                savedProviderID = provider.id
            }
            statusSucceeded = true
            statusMessage = String(localized: "ai_provider_saved", defaultValue: "Provider saved")
            onChanged()
            refresh()
        } catch {
            showFailure()
        }
    }

    /** Creates or replaces a Keychain credential without persisting it elsewhere. */
    private func saveCredential() {
        guard let savedProviderID, !credentialDraft.isEmpty else { return }
        do {
            try credentialStore.setCredential(credentialDraft, for: savedProviderID)
            credentialDraft = ""
            hasCredential = true
            statusMessage = nil
            onChanged()
            refresh()
        } catch {
            credentialDraft = ""
            showFailure()
        }
    }

    /** Deletes only the provider's device-local Keychain credential. */
    private func deleteCredential() {
        guard let savedProviderID else { return }
        do {
            try credentialStore.removeCredential(for: savedProviderID)
            credentialDraft = ""
            hasCredential = false
            statusMessage = nil
            onChanged()
            refresh()
        } catch {
            showFailure()
        }
    }

    /** Sets one configured model as the global default. */
    private func setDefaultModel(_ modelID: UUID) {
        do {
            let settings = try settingsStore.globalSettings()
            settings.defaultModelId = modelID
            try settingsStore.save()
            onChanged()
            refresh()
        } catch {
            showFailure()
        }
    }

    /** Deletes one configured model and its dependent references and usage. */
    private func deleteModel(_ modelID: UUID) {
        do {
            try settingsStore.deleteModel(id: modelID)
            onChanged()
            refresh()
        } catch {
            showFailure()
        }
    }

    /** Resolves and tests the provider's default or first configured model. */
    private func testConnection() {
        guard let candidate = models.first(where: { $0.id == defaultModelID }) ?? models.first else { return }
        let resolver = AIModelResolver(settingsStore: settingsStore, credentialStore: credentialStore)
        let resolved: ResolvedLLMModel
        do {
            resolved = try resolver.resolve(configuredModelId: candidate.id)
        } catch {
            showFailure()
            return
        }
        testing = true
        statusMessage = nil
        Task {
            do {
                _ = try await AIConnectionTester().test(model: resolved)
                await MainActor.run {
                    testing = false
                    statusSucceeded = true
                    statusMessage = String(localized: "easy_setup_success", defaultValue: "Connection successful!")
                }
            } catch {
                await MainActor.run {
                    testing = false
                    statusSucceeded = false
                    statusMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
                }
            }
        }
    }

    /** Removes the credential before deleting provider, model, usage, and override rows. */
    private func deleteProvider() {
        guard let savedProviderID else { return }
        do {
            try credentialStore.removeCredential(for: savedProviderID)
            try settingsStore.deleteProvider(id: savedProviderID)
            onChanged()
            dismiss()
        } catch {
            showFailure()
        }
    }

    /** Invalidates fetched rows without retaining any sensitive form value. */
    private func refresh() {
        revision &+= 1
    }

    /** Presents the shared credential-free failure text. */
    private func showFailure() {
        statusSucceeded = false
        statusMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
    }
}

/** Editor for one configured model and its optional cost metadata. */
private struct AIModelEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let providerID: UUID
    let modelID: UUID?
    let onSaved: () -> Void

    @State private var modelName = ""
    @State private var inputPrice = "0"
    @State private var outputPrice = "0"
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }

    var body: some View {
        Form {
            Section(String(localized: "llm_openrouter_model", defaultValue: "Model")) {
                TextField(
                    String(localized: "llm_custom_model_dialog_message", defaultValue: "Enter the model ID"),
                    text: $modelName
                )
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            }
            Section(String(localized: "ai_usage_category", defaultValue: "Usage")) {
                priceField(String(localized: "llm_custom_input_price_title", defaultValue: "Input price ($/Mtoken)"), text: $inputPrice)
                priceField(String(localized: "llm_custom_output_price_title", defaultValue: "Output price ($/Mtoken)"), text: $outputPrice)
            }
        }
        .navigationTitle(String(localized: "llm_openrouter_model", defaultValue: "Model"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel", defaultValue: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "save", defaultValue: "Save")) { save() }
                    .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { load() }
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

    /** Builds a decimal pricing field with platform-appropriate keyboard behavior. */
    @ViewBuilder
    private func priceField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }

    /** Loads an existing model into editable non-secret state. */
    private func load() {
        guard let modelID, let model = try? settingsStore.model(id: modelID) else { return }
        modelName = model.modelId
        inputPrice = String(model.inputPricePerMillion)
        outputPrice = String(model.outputPricePerMillion)
    }

    /** Inserts or updates a model and its pricing metadata. */
    private func save() {
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        do {
            if let modelID, let model = try settingsStore.model(id: modelID) {
                model.modelId = trimmedName
                model.inputPricePerMillion = max(Double(inputPrice) ?? 0, 0)
                model.outputPricePerMillion = max(Double(outputPrice) ?? 0, 0)
                try settingsStore.save()
            } else {
                let model = LLMConfiguredModel(
                    providerConfigId: providerID,
                    modelId: trimmedName,
                    orderNumber: (try? settingsStore.models(providerConfigId: providerID).count) ?? 0,
                    inputPricePerMillion: max(Double(inputPrice) ?? 0, 0),
                    outputPricePerMillion: max(Double(outputPrice) ?? 0, 0)
                )
                try settingsStore.insertModel(model)
                let settings = try settingsStore.globalSettings()
                if settings.defaultModelId == nil {
                    settings.defaultModelId = model.id
                    try settingsStore.save()
                }
            }
            onSaved()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}
