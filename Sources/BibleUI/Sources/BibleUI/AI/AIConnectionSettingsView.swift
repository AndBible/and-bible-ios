// AIConnectionSettingsView.swift -- Android-parity AI connection hierarchy

import BibleCore
import Foundation
import SwiftData
import SwiftUI
import SwordKit

/** Provider-count-dependent visibility for Android's Connection settings screen. */
struct AIConnectionSettingsVisibility: Equatable {
    /// Quick Setup is offered only before the first provider is created.
    let showsQuickSetup: Bool
    /// Models, behavior, advanced, and usage are hidden until a provider exists.
    let showsConfiguredSections: Bool

    /**
     Resolves conditional rows from the number of persisted providers.

     - Parameter providerCount: Number of provider configuration rows.
     - Returns: Android's zero-provider or configured visibility state.
     - Side effects: None. The result is deterministic for the supplied count.
     */
    static func resolve(providerCount: Int) -> Self {
        let hasProviders = providerCount > 0
        return Self(
            showsQuickSetup: !hasProviders,
            showsConfiguredSections: hasProviders
        )
    }
}

/**
 App-owned Connection settings destination matching Android's preference hierarchy.

 The screen observes provider and model rows from SwiftData, presents the disclaimer first, and
 applies Android's provider-count visibility rules. Providers and Models are navigation-stack
 destinations; disclaimer and Quick Setup use Android-style dialogs over this screen.
 */
struct AIConnectionSettingsView: View {
    /// SwiftData context used only by the debug reset action and summary lookups.
    @Environment(\.modelContext) private var modelContext
    /// Live provider rows drive conditional section visibility and summaries.
    @Query private var providerConfigurations: [LLMProviderConfig]
    /// Live configured models drive Android's Models summary.
    @Query private var configuredModels: [LLMConfiguredModel]
    /// Live usage rows drive Android's nonselectable token/cost summary.
    @Query private var usageRecords: [LLMUsageRecord]

    /// Optional installed-module manager forwarded to AI policy destinations.
    let swordManager: SwordManager?
    /// Device-only credential boundary forwarded to provider flows.
    let credentialStore: AICredentialStore

    /// Credential-free failure text for debug reset errors.
    @State private var failureMessage: String?
    /// Android dialog currently presented over Connection settings.
    @State private var activeDialog: AIConfigurationDialog?
    /// Persisted response language; `nil` inherits the app language.
    @State private var responseLanguage: String?
    /// Global agent permission mode shown in the Android list preference.
    @State private var permissionMode = AIPermissionMode.alwaysAsk
    /// Number of per-tool overrides summarized on the Connection screen.
    @State private var toolPermissionOverrideCount = 0
    /// Number of installed documents excluded from AI access.
    @State private var excludedDocumentCount = 0
    /// Commentary token ceiling, where zero means unlimited.
    @State private var commentaryResponseLimit = 15_000
    /// Maximum agent iterations, where zero means unlimited.
    @State private var maximumAgentIterations = 10
    /// Whether prompt execution asks for a model when no override exists.
    @State private var asksModelBeforeRun = false
    /// Whether successful or cancelled runs hide their AI panel.
    @State private var hidesCompletedAIPanel = false
    /// Optional ordinary-agent system-prompt override.
    @State private var agentSystemPrompt: String?
    /// Optional text-transformation system-prompt override.
    @State private var transformationSystemPrompt: String?
    /// Nullable Android raw-log retention setting.
    @State private var rawLogRetentionDays: Int? = 30
    /// Prevents initial state hydration from writing defaults back to SwiftData.
    @State private var hasLoadedSettings = false

    /// Providers in Android's persisted display order.
    private var providers: [LLMProviderConfig] {
        providerConfigurations.sorted {
            if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Models in Android's default-first display order.
    private var models: [LLMConfiguredModel] {
        let defaultModelID = try? AISettingsStore(modelContext: modelContext).globalSettings().defaultModelId
        return configuredModels.sorted { lhs, rhs in
            let lhsIsDefault = lhs.id == defaultModelID
            let rhsIsDefault = rhs.id == defaultModelID
            if lhsIsDefault != rhsIsDefault { return lhsIsDefault }
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            return lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
        }
    }

    /// Android's current section visibility for the live provider population.
    private var visibility: AIConnectionSettingsVisibility {
        .resolve(providerCount: providers.count)
    }

    var body: some View {
        List {
            Section {
                Button {
                    activeDialog = .disclaimerInformation
                } label: {
                    AIConnectionSettingsRow(
                        title: String(
                            localized: "ai_disclaimer_warning_title",
                            defaultValue: "Important: Read before using AI tools"
                        ),
                        summary: String(
                            localized: "ai_disclaimer_warning_summary",
                            defaultValue: "Risks and responsibilities of using AI"
                        ),
                        systemImage: "exclamationmark.triangle.fill",
                        imageColor: .red
                    )
                }
                .accessibilityIdentifier("aiDisclaimerInformationLink")
            }

            Section(String(localized: "ai_providers_models_category", defaultValue: "Providers & Models")) {
                if visibility.showsQuickSetup {
                    Button {
                        requestConfiguration(.quickSetup)
                    } label: {
                        AIConnectionSettingsRow(
                            title: String(localized: "easy_setup_title", defaultValue: "Quick Setup"),
                            summary: String(
                                localized: "easy_setup_pref_summary",
                                defaultValue: "Set up AI with a recommended provider in a few steps"
                            ),
                            systemImage: "cloud"
                        )
                    }
                    .accessibilityIdentifier("aiQuickSetupButton")
                }

                NavigationLink {
                    AIProvidersView(credentialStore: credentialStore)
                } label: {
                    AIConnectionSettingsRow(
                        title: String(localized: "ai_providers_category", defaultValue: "Providers"),
                        summary: providerSummary,
                        systemImage: "cloud"
                    )
                }
                .accessibilityIdentifier("aiProvidersLink")

                if visibility.showsConfiguredSections {
                    NavigationLink {
                        AIModelsView()
                    } label: {
                        AIConnectionSettingsRow(
                            title: String(localized: "ai_models_category", defaultValue: "Models"),
                            summary: modelSummary,
                            systemImage: "cpu"
                        )
                    }
                    .accessibilityIdentifier("aiModelsLink")
                }
            }

            if visibility.showsConfiguredSections {
                behaviorSection
                advancedSection
                usageSection

            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("aiConnectionSettingsScreen")
        .navigationTitle(String(localized: "ai_connection_settings", defaultValue: "Connection settings"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        activeDialog = .information(
                            title: String(localized: "help", defaultValue: "Help"),
                            message: String(
                                localized: "help_ai_connection_text",
                                defaultValue: "Configure your AI providers, models, permissions and other connection options here. Each provider needs its own API key. You can add multiple providers and select a default model."
                            )
                        )
                    } label: {
                        Label(String(localized: "help", defaultValue: "Help"), systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
                .disabled(activeDialog != nil)
            }
        }
        .aiConfigurationDialog(
            $activeDialog,
            credentialStore: credentialStore,
            onChanged: refreshSettings
        )
        .task { refreshSettings() }
        .onChange(of: asksModelBeforeRun) { persistInlineSwitchesIfLoaded() }
        .onChange(of: hidesCompletedAIPanel) { persistInlineSwitchesIfLoaded() }
        .overlay {
            if let message = failureMessage {
                AndroidMyDocumentDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /// Android's Behavior rows with their exact dialog, destination, or inline-switch interaction.
    private var behaviorSection: some View {
        Section(String(localized: "ai_behavior_category", defaultValue: "Behavior")) {
            Button {
                activeDialog = .responseLanguage(currentCode: responseLanguage)
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "ai_language_title", defaultValue: "AI response language"),
                    summary: responseLanguageSummary,
                    systemImage: "doc.text"
                )
            }
            Button {
                activeDialog = .permissionMode(permissionMode)
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
                    summary: String(
                        localized: "agent_permission_mode_summary",
                        defaultValue: "Controls when user confirmation is required before AI write operations"
                    ),
                    systemImage: "shield"
                )
            }
            NavigationLink {
                AIToolPermissionsView()
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "manage_tool_permissions_title", defaultValue: "Tool permissions"),
                    summary: toolPermissionsSummary,
                    systemImage: "shield"
                )
            }
            NavigationLink {
                AIDocumentAccessView(swordManager: swordManager)
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "ai_document_filter_title", defaultValue: "Document access"),
                    summary: documentAccessSummary,
                    systemImage: "doc.text"
                )
            }
            Button {
                activeDialog = .commentaryResponseLimit(commentaryResponseLimit)
            } label: {
                AIConnectionSettingsRow(
                    title: String(
                        localized: "commentary_max_response_title",
                        defaultValue: "Commentary response size limit"
                    ),
                    summary: commentaryResponseSummary,
                    systemImage: "doc.text"
                )
            }
            Button {
                activeDialog = .maximumAgentIterations(maximumAgentIterations)
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "agent_max_iterations_title", defaultValue: "Max agent iterations"),
                    summary: maximumAgentIterationsSummary,
                    systemImage: "doc.text"
                )
            }
            Toggle(isOn: $asksModelBeforeRun) {
                AIConnectionSettingsRow(
                    title: String(localized: "ask_model_before_run_title", defaultValue: "Ask model before run"),
                    summary: String(
                        localized: "ask_model_before_run_summary",
                        defaultValue: "Show a model selection dialog before executing a prompt (skipped when the prompt has an explicit model override)"
                    ),
                    systemImage: "doc.text"
                )
            }
            Toggle(isOn: $hidesCompletedAIPanel) {
                AIConnectionSettingsRow(
                    title: String(
                        localized: "auto_hide_agent_log_title",
                        defaultValue: "Hide AI panel when done"
                    ),
                    summary: String(
                        localized: "auto_hide_agent_log_summary",
                        defaultValue: "Automatically hide the AI panel when a task finishes successfully or is cancelled. On error the panel stays visible."
                    ),
                    systemImage: "doc.text"
                )
            }
        }
    }

    /// Android's Advanced rows, each editing only its own bundled system-prompt override.
    private var advancedSection: some View {
        Section(String(localized: "ai_advanced_category", defaultValue: "Advanced")) {
            Button {
                activeDialog = .systemPrompt(kind: .agent, currentValue: agentSystemPrompt)
            } label: {
                AIConnectionSettingsRow(
                    title: String(
                        localized: "custom_agent_system_prompt_title",
                        defaultValue: "Agent system prompt"
                    ),
                    summary: systemPromptSummary(agentSystemPrompt),
                    systemImage: "doc.text"
                )
            }
            Button {
                activeDialog = .systemPrompt(kind: .transformation, currentValue: transformationSystemPrompt)
            } label: {
                AIConnectionSettingsRow(
                    title: String(
                        localized: "custom_text_transform_system_prompt_title",
                        defaultValue: "Text transformation system prompt"
                    ),
                    summary: systemPromptSummary(transformationSystemPrompt),
                    systemImage: "doc.text"
                )
            }
        }
    }

    /// Android's Usage rows with nonselectable totals, reset/retention dialogs, and log destination.
    private var usageSection: some View {
        Section(String(localized: "ai_usage_category", defaultValue: "Usage")) {
            AIConnectionSettingsRow(
                title: String(localized: "llm_usage_summary_title", defaultValue: "Token usage"),
                summary: usageSummary,
                systemImage: "doc.text"
            )
            Button {
                activeDialog = .resetUsage
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "llm_reset_usage_title", defaultValue: "Reset usage data"),
                    summary: String(
                        localized: "llm_reset_usage_summary",
                        defaultValue: "Clear cumulative token and cost tracking"
                    ),
                    systemImage: "arrow.clockwise"
                )
            }
            NavigationLink {
                AIRawLogHistoryView()
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "raw_log_history_title", defaultValue: "AI Log History"),
                    summary: String(
                        localized: "raw_log_history_summary",
                        defaultValue: "View and manage saved AI conversation logs"
                    ),
                    systemImage: "doc.text"
                )
            }
            Button {
                activeDialog = .rawLogRetention(rawLogRetentionDays)
            } label: {
                AIConnectionSettingsRow(
                    title: String(localized: "raw_log_retention_title", defaultValue: "Auto-delete old logs"),
                    summary: rawLogRetentionSummary,
                    systemImage: "trash"
                )
            }
        }
    }

    /// Comma-separated provider names, or Android's explicit empty summary.
    private var providerSummary: String {
        guard !providers.isEmpty else {
            return String(localized: "ai_providers_summary_none", defaultValue: "No providers configured")
        }
        return providers.map(\.displayName).joined(separator: ", ")
    }

    /// Default-first comma-separated model names, or Android's explicit empty summary.
    private var modelSummary: String {
        guard !models.isEmpty else {
            return String(localized: "ai_models_summary_none", defaultValue: "No models configured")
        }
        let defaultModelID = try? AISettingsStore(modelContext: modelContext).globalSettings().defaultModelId
        return models.map { model in
            model.id == defaultModelID ? "★ \(model.modelId)" : model.modelId
        }.joined(separator: ", ")
    }

    /// Android response-language summary using the selected language's own display name.
    private var responseLanguageSummary: String {
        guard let responseLanguage else {
            let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
            let language = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
            return String(
                format: String(localized: "ai_language_app_default", defaultValue: "App language (%1$@)"),
                language
            )
        }
        let locale = Locale(identifier: responseLanguage)
        let languageCode = locale.language.languageCode?.identifier ?? responseLanguage
        let displayName = locale.localizedString(forLanguageCode: languageCode) ?? responseLanguage
        return displayName.isEmpty || displayName == responseLanguage
            ? responseLanguage
            : "\(displayName) (\(responseLanguage))"
    }

    /// Android tool-permission summary with the total explicit override count appended when nonzero.
    private var toolPermissionsSummary: String {
        let base = String(
            localized: "manage_tool_permissions_summary",
            defaultValue: "Manage per-tool permission overrides"
        )
        return toolPermissionOverrideCount > 0 ? "\(base) (\(toolPermissionOverrideCount))" : base
    }

    /// Android document-access summary with the excluded-document count when nonzero.
    private var documentAccessSummary: String {
        guard excludedDocumentCount > 0 else {
            return String(
                localized: "ai_document_filter_summary",
                defaultValue: "Choose which documents the AI can read"
            )
        }
        return String(
            format: String(
                localized: "ai_document_filter_summary_count",
                defaultValue: "%d documents excluded"
            ),
            excludedDocumentCount
        )
    }

    /// Android commentary response-limit summary.
    private var commentaryResponseSummary: String {
        guard commentaryResponseLimit > 0 else {
            return String(localized: "commentary_max_response_no_limit", defaultValue: "No limit")
        }
        return String(
            format: String(localized: "commentary_max_response_value", defaultValue: "~%@ tokens"),
            commentaryResponseLimit.formatted()
        )
    }

    /// Android maximum-iterations summary including the current value or unlimited state.
    private var maximumAgentIterationsSummary: String {
        let base = String(
            localized: "agent_max_iterations_summary",
            defaultValue: "Maximum iterations before asking to continue (0 = unlimited)"
        )
        if maximumAgentIterations <= 0 {
            return "\(base) (\(String(localized: "prompt_max_iterations_unlimited", defaultValue: "Unlimited")))"
        }
        return "\(base) (\(maximumAgentIterations))"
    }

    /// Android default/custom state for one system-prompt override.
    private func systemPromptSummary(_ value: String?) -> String {
        if value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return String(localized: "custom_system_prompt_custom", defaultValue: "Custom")
        }
        return String(localized: "custom_system_prompt_default", defaultValue: "Default")
    }

    /// Android cumulative input/output token and estimated-cost summary across all devices/models.
    private var usageSummary: String {
        let inputTokens = usageRecords.reduce(into: 0) { $0 += $1.inputTokens }
        let outputTokens = usageRecords.reduce(into: 0) { $0 += $1.outputTokens }
        guard inputTokens > 0 || outputTokens > 0 else {
            return String(localized: "llm_usage_summary_default", defaultValue: "No usage data")
        }
        let cost = usageRecords.reduce(into: 0.0) { $0 += $1.estimatedCostUSD }
        let costText = cost > 0 && cost < 0.01
            ? String(format: "$%.3f", cost)
            : String(format: "$%.2f", cost)
        return String(
            format: String(
                localized: "llm_usage_summary_format",
                defaultValue: "Input: %1$d tokens | Output: %2$d tokens\nEstimated cost: %3$@"
            ),
            inputTokens,
            outputTokens,
            costText
        )
    }

    /// Android nullable raw-log retention summary.
    private var rawLogRetentionSummary: String {
        guard let rawLogRetentionDays else {
            return String(
                localized: "raw_log_retention_summary_disabled",
                defaultValue: "Disabled (keep all)"
            )
        }
        return String(
            format: String(localized: "raw_log_retention_summary_days", defaultValue: "After %d days"),
            rawLogRetentionDays
        )
    }

    /**
     Rehydrates every Connection summary and switch from Android's singleton settings row.

     - Side effects: Reads SwiftData and replaces view-local presentation state on the main actor.
     - Failure modes: Persistence failures leave the prior state visible and show localized error copy.
     */
    private func refreshSettings() {
        do {
            let settings = try AISettingsStore(modelContext: modelContext).globalSettings()
            responseLanguage = settings.aiLanguage
            permissionMode = settings.agentPermissionMode ?? .alwaysAsk
            toolPermissionOverrideCount = (settings.permanentlyAllowedTools ?? []).count
                + (settings.permanentlyDeniedTools ?? []).count
            excludedDocumentCount = settings.aiExcludedDocuments.count
            commentaryResponseLimit = settings.commentaryMaxResponseTokens
            maximumAgentIterations = settings.maxIterations
            asksModelBeforeRun = settings.askModelBeforeRun
            hidesCompletedAIPanel = settings.autoHideAgentLogOnCompletion
            agentSystemPrompt = settings.customAgentSystemPrompt
            transformationSystemPrompt = settings.customTextTransformationSystemPrompt
            rawLogRetentionDays = settings.rawLogRetentionDays
            hasLoadedSettings = true
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Persists Android's two inline switch preferences after initial hydration.

     - Side effects: Writes both switch values to the singleton SwiftData settings row and saves once.
     - Failure modes: Initial load is ignored; save failures restore durable values on the next refresh
       and show localized error copy without exposing persistence details.
     */
    private func persistInlineSwitchesIfLoaded() {
        guard hasLoadedSettings else { return }
        do {
            let store = AISettingsStore(modelContext: modelContext)
            let settings = try store.globalSettings()
            settings.askModelBeforeRun = asksModelBeforeRun
            settings.autoHideAgentLogOnCompletion = hidesCompletedAIPanel
            try store.save()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Opens Quick Setup immediately or through Android's durable disclaimer gate.

     - Parameter request: Protected configuration action selected on this screen.
     - Side effects: Reads the global acceptance flag and updates the parent-owned dialog state.
     - Failure modes: Persistence failures leave the screen in place and show localized error copy.
     */
    private func requestConfiguration(_ request: AIConfigurationEntryRequest) {
        do {
            let accepted = try AISettingsStore(modelContext: modelContext)
                .globalSettings()
                .aiDisclaimerAccepted
            activeDialog = .initial(for: request, isDisclaimerAccepted: accepted)
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

}

/** Compact title-and-summary row matching Android's preference presentation. */
private struct AIConnectionSettingsRow: View {
    /// Primary row title.
    let title: String
    /// Optional secondary summary beneath the title.
    var summary: String?
    /// Optional leading symbol used only when Android supplies a semantic icon.
    var systemImage: String?
    /// Optional semantic symbol color.
    var imageColor: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(imageColor)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/** App-owned provider list with Android's blank empty state and toolbar Add action. */
private struct AIProvidersView: View {
    /// SwiftData context used to read the durable disclaimer gate.
    @Environment(\.modelContext) private var modelContext
    /// Live provider rows keep the list current after pushed editor changes.
    @Query private var providerConfigurations: [LLMProviderConfig]

    /// Device-only credential boundary forwarded to provider editors.
    let credentialStore: AICredentialStore

    /// Android dialog currently presented over the Providers screen.
    @State private var activeDialog: AIConfigurationDialog?
    /// Credential-free persistence failure text.
    @State private var failureMessage: String?

    /// Providers in Android's persisted display order.
    private var providers: [LLMProviderConfig] {
        providerConfigurations.sorted {
            if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        List {
            ForEach(providers) { provider in
                Button {
                    activeDialog = .providerEditor(
                        providerID: provider.id,
                        providerType: provider.provider
                    )
                } label: {
                    AIConnectionSettingsRow(
                        title: provider.displayName,
                        summary: credentialSummary(for: provider.id),
                        systemImage: "cloud"
                    )
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("aiProvidersScreen")
        .navigationTitle(String(localized: "ai_providers_category", defaultValue: "Providers"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    requestAddProvider()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "ai_add_provider", defaultValue: "Add provider"))
                .accessibilityIdentifier("aiAddProviderLink")
                .disabled(activeDialog != nil)
                Menu {
                    Button {
                        activeDialog = .information(
                            title: String(localized: "help", defaultValue: "Help"),
                            message: String(
                                localized: "help_ai_providers_text",
                                defaultValue: "Manage AI providers (Google Gemini, OpenAI, Anthropic, etc.). Each provider needs its own API key. You can add multiple providers and assign different ones to specific prompts."
                            )
                        )
                    } label: {
                        Label(String(localized: "help", defaultValue: "Help"), systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(String(localized: "system_items1", defaultValue: "More"))
                .disabled(activeDialog != nil)
            }
        }
        .aiConfigurationDialog(
            $activeDialog,
            credentialStore: credentialStore
        )
        .overlay {
            if let message = failureMessage {
                AndroidMyDocumentDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /// Android's API-key suffix summary without retaining the credential beyond this evaluation.
    private func credentialSummary(for providerID: UUID) -> String {
        guard let credential = credentialStore.credential(for: providerID), !credential.isEmpty else {
            return String(localized: "ai_provider_api_key_not_set", defaultValue: "API key not set")
        }
        return String(
            format: "%@: ●●●●%@",
            String(localized: "ai_provider_api_key", defaultValue: "API key"),
            String(credential.suffix(4))
        )
    }

    /** Opens Add Provider immediately or through Android's durable disclaimer gate. */
    private func requestAddProvider() {
        do {
            let accepted = try AISettingsStore(modelContext: modelContext)
                .globalSettings()
                .aiDisclaimerAccepted
            activeDialog = .initial(for: .addProvider, isDisclaimerAccepted: accepted)
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}
