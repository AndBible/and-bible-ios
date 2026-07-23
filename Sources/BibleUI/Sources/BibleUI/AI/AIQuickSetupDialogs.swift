// AIQuickSetupDialogs.swift -- Android three-dialog AI setup workflow

import BibleCore
import Foundation
import SwiftData
import SwiftUI

/** Android's first Quick Setup dialog for choosing one recommended provider and model. */
struct AIQuickSetupProviderDialog: View {
    /// Provider selection callback that advances to API-key entry.
    let onSelect: (AIRecommendedSetup) -> Void
    /// Negative action callback.
    let onCancel: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "easy_setup_title", defaultValue: "Quick Setup")
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AIRecommendedSetupCatalog.options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        Text(optionLabel(option))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("aiQuickSetupProvider_\(option.provider.rawValue)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aiQuickSetupProviderList")
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiQuickSetupCancelButton")
        }
    }

    /// Android's one-line provider, description, and optional badge label.
    private func optionLabel(_ option: AIRecommendedSetup) -> String {
        let description: String
        let badge: String?
        switch option.provider {
        case .gemini:
            description = String(
                localized: "easy_setup_gemini_desc",
                defaultValue: "Free tier available, good quality"
            )
            badge = String(localized: "easy_setup_free_tier", defaultValue: "Free tier")
        case .anthropic:
            description = String(
                localized: "easy_setup_anthropic_desc",
                defaultValue: "Affordable, excellent quality"
            )
            badge = nil
        case .openAI:
            description = String(
                localized: "easy_setup_openai_desc",
                defaultValue: "Well-known, reliable"
            )
            badge = nil
        default:
            description = option.modelID
            badge = nil
        }
        let base = "\(AIProviderPresentation.displayName(for: option.provider)) — \(description)"
        return badge.map { "\(base) (\($0))" } ?? base
    }
}

/** Android's second Quick Setup dialog for API-key entry and connection testing. */
struct AIQuickSetupCredentialDialog: View {
    /// SwiftData context used for the provider, model, and default-model transaction.
    @Environment(\.modelContext) private var modelContext

    /// Current appearance used by the shared AppCompat dialog marker.
    @Environment(\.colorScheme) private var colorScheme

    /// Selected Android-recommended setup.
    let option: AIRecommendedSetup
    /// Device-local Keychain boundary.
    let credentialStore: AICredentialStore
    /// Negative action callback.
    let onCancel: () -> Void
    /// Callback after provider, credential, model, and default selection all commit.
    let onSaved: () -> Void

    /// Transient visible API key, matching Android's visible-password field.
    @State private var apiKey = ""
    /// Whether a connection test is currently in flight.
    @State private var testing = false
    /// Localized test or save status.
    @State private var statusMessage: String?
    /// Whether the current status is successful.
    @State private var statusSucceeded = false

    var body: some View {
        AIAndroidDialogSurface(title: dialogTitle) {
            AndroidAdaptiveDialogScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        String(
                            localized: "easy_setup_api_key_instructions",
                            defaultValue: "Get your API key from:"
                        )
                    )
                    if let apiKeyURL {
                        AndroidDialogLink(
                            AIProviderPresentation.displayName(for: option.provider),
                            destination: apiKeyURL
                        )
                    }

                    TextField(
                        String(localized: "ai_provider_api_key", defaultValue: "API key"),
                        text: $apiKey
                    )
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityIdentifier("aiQuickSetupAPIKeyField")

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(statusSucceeded ? Color.green : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        } actions: {
            AIAndroidDialogAction(
                title: testing
                    ? String(localized: "easy_setup_testing", defaultValue: "Testing…")
                    : String(localized: "easy_setup_test_connection", defaultValue: "Test connection"),
                isEnabled: !testing,
                action: testConnection
            )
            .accessibilityIdentifier("aiQuickSetupTestButton")
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiQuickSetupCancelButton")
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                isEnabled: !trimmedAPIKey.isEmpty && !testing,
                action: saveSetup
            )
            .accessibilityIdentifier("aiQuickSetupSaveButton")
        }
        .androidAccessibilityIdentityMarker(
            label: dialogTitle,
            accessibilityIdentifier: "aiQuickSetupCredentialScreen",
            surfaceColor: AndroidDialogSurfacePalette.background(for: colorScheme)
        )
        .onDisappear { apiKey = "" }
    }

    /// Android's provider-specific API-key dialog title.
    private var dialogTitle: String {
        "\(String(localized: "easy_setup_enter_api_key", defaultValue: "Enter your API key")) — \(AIProviderPresentation.displayName(for: option.provider))"
    }

    /// Whitespace-trimmed credential used for network and Keychain calls.
    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Android's provider-specific API-key destination.
    private var apiKeyURL: URL? {
        let rawURL: String
        switch option.provider {
        case .gemini: rawURL = "https://aistudio.google.com/apikey"
        case .openAI: rawURL = "https://platform.openai.com/api-keys"
        case .anthropic: rawURL = "https://console.anthropic.com/settings/keys"
        default: return nil
        }
        return URL(string: rawURL)
    }

    /**
     Tests the transient key without inserting provider, model, or secret state.

     - Side effects: Performs one provider request when the key is non-empty.
     - Failure modes: Transport and provider failures become credential-free visible status text.
     */
    private func testConnection() {
        guard !trimmedAPIKey.isEmpty else { return }
        let transient = ResolvedLLMModel(
            configuredModelId: UUID(),
            providerConfigId: UUID(),
            modelId: option.modelID,
            apiFormat: option.provider.apiFormat,
            endpoint: option.provider.endpoint!,
            credential: trimmedAPIKey,
            supportsCacheControl: option.provider.supportsCacheControl
        )
        testing = true
        statusMessage = String(localized: "easy_setup_testing", defaultValue: "Testing…")
        Task {
            do {
                _ = try await AIConnectionTester().test(model: transient)
                await MainActor.run {
                    testing = false
                    statusSucceeded = true
                    statusMessage = String(
                        localized: "easy_setup_success",
                        defaultValue: "Connection successful!"
                    )
                }
            } catch {
                await MainActor.run {
                    testing = false
                    statusSucceeded = false
                    statusMessage = String(
                        localized: "error_occurred",
                        defaultValue: "An error has occurred"
                    )
                }
            }
        }
    }

    /**
     Commits Android's recommended provider, credential, model, and global default tuple.

     - Side effects: Inserts SwiftData rows, writes Keychain, sets the global default, starts a
       best-effort sanitized dynamic-model cache refresh, clears the transient key, and advances to
       the completion dialog.
     - Failure modes: Any failure removes staged provider and credential data and leaves this dialog
       visible with credential-free error text.
     */
    private func saveSetup() {
        guard !trimmedAPIKey.isEmpty else { return }
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
                try credentialStore.setCredential(trimmedAPIKey, for: provider.id)
                try store.insertModel(model)
                let settings = try store.globalSettings()
                settings.defaultModelId = model.id
                try store.save()
                let refreshCredential = trimmedAPIKey
                if let refreshEndpoint = option.provider.endpoint,
                   AIModelCatalog.supportsDynamicModels(option.provider) {
                    Task {
                        await AIDynamicModelService.shared.refreshIfNeeded(
                            provider: option.provider,
                            endpoint: refreshEndpoint,
                            credential: refreshCredential
                        )
                    }
                }
                apiKey = ""
                onSaved()
            } catch {
                try? credentialStore.removeCredential(for: provider.id)
                try? store.deleteProvider(id: provider.id)
                throw error
            }
        } catch {
            statusSucceeded = false
            statusMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Android's final Quick Setup acknowledgement dialog. */
struct AIQuickSetupCompleteDialog: View {
    /// Positive action callback.
    let onDone: () -> Void

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "easy_setup_done_title", defaultValue: "AI is ready!")
        ) {
            Text(
                String(
                    localized: "easy_setup_done_message",
                    defaultValue: "Select text in the Bible and try the AI features. You can add more models and providers in the settings."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "okay", defaultValue: "OK"),
                action: onDone
            )
            .accessibilityIdentifier("aiQuickSetupDoneButton")
        }
    }
}
