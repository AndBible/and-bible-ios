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

/** Full-screen app-owned destinations reached from Android Connection settings preferences. */
private enum AIConnectionSettingsActivity: Equatable {
    case providers
    case models
    case toolPermissions
    case documentAccess
    case rawLogHistory
}

/**
 App-owned Connection settings destination matching Android's preference hierarchy.

 The screen observes provider and model rows from SwiftData, presents the disclaimer first, and
 applies Android's provider-count visibility rules. Providers and Models are navigation-stack
 destinations; disclaimer and Quick Setup use Android-style dialogs over this screen.
 */
struct AIConnectionSettingsView: View {
    /// Pops the app-owned activity for standalone callers.
    @Environment(\.dismiss) private var dismiss
    /// Current appearance used by the shared popup surface.
    @Environment(\.colorScheme) private var colorScheme
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
    /// Reader/workspace palette shared across the Connection settings hierarchy.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command supplied by the owning AI Settings activity.
    let onBack: (() -> Void)?

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
    /// Nested Android activity currently replacing the Connection settings root.
    @State private var activeActivity: AIConnectionSettingsActivity?
    /// Whether Android's app-owned toolbar overflow popup is visible.
    @State private var showsOverflowMenu = false

    /**
     Creates the app-owned Connection settings hierarchy.

     - Parameters:
       - swordManager: Optional installed-module source for document access.
       - credentialStore: Device-only provider credential boundary.
       - surfacePalette: Owner-resolved application/workspace palette.
       - onBack: Explicit Android Up action; nil uses environment dismissal.
     - Side effects: none during construction.
     - Failure modes: child persistence failures are surfaced inside their owning activity.
     */
    init(
        swordManager: SwordManager?,
        credentialStore: AICredentialStore,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.swordManager = swordManager
        self.credentialStore = credentialStore
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

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
        Group {
            switch activeActivity {
            case .providers:
                AIProvidersView(
                    credentialStore: credentialStore,
                    surfacePalette: surfacePalette,
                    onBack: { activeActivity = nil }
                )
            case .models:
                AIModelsView(
                    surfacePalette: surfacePalette,
                    onBack: { activeActivity = nil }
                )
            case .toolPermissions:
                AIToolPermissionsView(
                    surfacePalette: surfacePalette,
                    onBack: { activeActivity = nil }
                )
            case .documentAccess:
                AIDocumentAccessView(
                    swordManager: swordManager,
                    surfacePalette: surfacePalette,
                    onBack: { activeActivity = nil }
                )
            case .rawLogHistory:
                AIRawLogHistoryView(
                    surfacePalette: surfacePalette,
                    onBack: { activeActivity = nil }
                )
            case nil:
                connectionSettingsRoot
            }
        }
    }

    /** Full app-owned root activity for Android Connection settings. */
    private var connectionSettingsRoot: some View {
        AndroidActivityScreen(
            title: String(localized: "ai_connection_settings", defaultValue: "Connection settings"),
            accessibilityIdentifier: "aiConnectionSettingsTopAppBar",
            palette: surfacePalette,
            onBack: performBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "aiConnectionSettingsOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                showsOverflowMenu.toggle()
            }
            .androidPopupMenuAnchor(id: "aiConnectionSettingsOverflowAnchor")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    disclaimerSection
                    providersAndModelsSection
                    if visibility.showsConfiguredSections {
                        behaviorSection
                        advancedSection
                        usageSection
                    }
                }
                .padding(.vertical, 8)
            }
            .disabled(activeDialog != nil || showsOverflowMenu)
        }
        .androidAccessibilityIdentityMarker(
            label: String(localized: "ai_connection_settings", defaultValue: "Connection settings"),
            accessibilityIdentifier: "aiConnectionSettingsScreen",
            surfaceColor: surfacePalette.backgroundColor
        )
        .androidAnchoredPopupMenu(
            anchorID: "aiConnectionSettingsOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 220,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "aiConnectionSettingsOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiConnectionSettingsOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "help", defaultValue: "Help"),
                    icon: .asset("DrawerHelp"),
                    accessibilityIdentifier: "aiConnectionSettingsHelpMenuItem"
                ) {
                    showsOverflowMenu = false
                    activeDialog = .help(.aiConnection)
                }
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
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Android warning row shown before provider configuration. */
    private var disclaimerSection: some View {
        AndroidPreferenceSection(palette: surfacePalette) {
            AndroidCatalogActionPreferenceRow(
                title: String(
                    localized: "ai_disclaimer_warning_title",
                    defaultValue: "Important: Read before using AI tools"
                ),
                summary: String(
                    localized: "ai_disclaimer_warning_summary",
                    defaultValue: "Risks and responsibilities of using AI"
                ),
                icon: aiPreferenceIcon("ai_disclaimer_warning"),
                iconColor: .red,
                palette: surfacePalette,
                accessibilityIdentifier: "aiDisclaimerInformationLink"
            ) {
                activeDialog = .disclaimerInformation
            }
        }
    }

    /** Android Providers & Models preference category. */
    private var providersAndModelsSection: some View {
        AndroidPreferenceSection(
            title: String(localized: "ai_providers_models_category", defaultValue: "Providers & Models"),
            palette: surfacePalette
        ) {
            if visibility.showsQuickSetup {
                AndroidCatalogActionPreferenceRow(
                    title: String(localized: "easy_setup_title", defaultValue: "Quick Setup"),
                    summary: String(
                        localized: "easy_setup_pref_summary",
                        defaultValue: "Set up AI with a recommended provider in a few steps"
                    ),
                    icon: aiPreferenceIcon("ai_getting_started"),
                    palette: surfacePalette,
                    accessibilityIdentifier: "aiQuickSetupButton"
                ) {
                    requestConfiguration(.quickSetup)
                }
                AndroidPreferenceDivider(palette: surfacePalette)
            }

            AndroidCatalogActionPreferenceRow(
                title: String(localized: "ai_providers_category", defaultValue: "Providers"),
                summary: providerSummary,
                icon: aiPreferenceIcon("ai_providers_shortcut"),
                palette: surfacePalette,
                accessibilityIdentifier: "aiProvidersLink"
            ) {
                activeActivity = .providers
            }

            if visibility.showsConfiguredSections {
                AndroidPreferenceDivider(palette: surfacePalette)
                AndroidCatalogActionPreferenceRow(
                    title: String(localized: "ai_models_category", defaultValue: "Models"),
                    summary: modelSummary,
                    icon: aiPreferenceIcon("ai_models_shortcut"),
                    palette: surfacePalette,
                    accessibilityIdentifier: "aiModelsLink"
                ) {
                    activeActivity = .models
                }
            }
        }
    }

    /// Android's Behavior rows with their exact dialog, destination, or inline-switch interaction.
    private var behaviorSection: some View {
        AndroidPreferenceSection(
            title: String(localized: "ai_behavior_category", defaultValue: "Behavior"),
            palette: surfacePalette
        ) {
            preferenceAction(
                key: "ai_language",
                title: String(localized: "ai_language_title", defaultValue: "AI response language"),
                summary: responseLanguageSummary,
                identifier: "aiLanguagePreference"
            ) { activeDialog = .responseLanguage(currentCode: responseLanguage) }
            preferenceDivider
            preferenceAction(
                key: "agent_permission_mode",
                title: String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
                summary: String(
                    localized: "agent_permission_mode_summary",
                    defaultValue: "Controls when user confirmation is required before AI write operations"
                ),
                identifier: "aiPermissionModePreference"
            ) { activeDialog = .permissionMode(permissionMode) }
            preferenceDivider
            preferenceAction(
                key: "manage_tool_permissions",
                title: String(localized: "manage_tool_permissions_title", defaultValue: "Tool permissions"),
                summary: toolPermissionsSummary,
                identifier: "aiToolPermissionsLink"
            ) { activeActivity = .toolPermissions }
            preferenceDivider
            preferenceAction(
                key: "manage_ai_documents",
                title: String(localized: "ai_document_filter_title", defaultValue: "Document access"),
                summary: documentAccessSummary,
                identifier: "aiDocumentAccessLink"
            ) { activeActivity = .documentAccess }
            preferenceDivider
            preferenceAction(
                key: "commentary_max_response_chars",
                title: String(
                    localized: "commentary_max_response_title",
                    defaultValue: "Commentary response size limit"
                ),
                summary: commentaryResponseSummary,
                identifier: "aiCommentaryResponseLimitPreference"
            ) { activeDialog = .commentaryResponseLimit(commentaryResponseLimit) }
            preferenceDivider
            preferenceAction(
                key: "agent_max_iterations",
                title: String(localized: "agent_max_iterations_title", defaultValue: "Max agent iterations"),
                summary: maximumAgentIterationsSummary,
                identifier: "aiMaximumIterationsPreference"
            ) { activeDialog = .maximumAgentIterations(maximumAgentIterations) }
            preferenceDivider
            AndroidCatalogSwitchPreferenceRow(
                title: String(localized: "ask_model_before_run_title", defaultValue: "Ask model before run"),
                summary: String(
                    localized: "ask_model_before_run_summary",
                    defaultValue: "Show a model selection dialog before executing a prompt (skipped when the prompt has an explicit model override)"
                ),
                icon: aiPreferenceIcon("ask_model_before_run"),
                isOn: $asksModelBeforeRun,
                palette: surfacePalette,
                accessibilityIdentifier: "aiAskModelBeforeRunSwitch"
            )
            preferenceDivider
            AndroidCatalogSwitchPreferenceRow(
                title: String(
                    localized: "auto_hide_agent_log_title",
                    defaultValue: "Hide AI panel when done"
                ),
                summary: String(
                    localized: "auto_hide_agent_log_summary",
                    defaultValue: "Automatically hide the AI panel when a task finishes successfully or is cancelled. On error the panel stays visible."
                ),
                icon: aiPreferenceIcon("auto_hide_agent_log_on_completion"),
                isOn: $hidesCompletedAIPanel,
                palette: surfacePalette,
                accessibilityIdentifier: "aiAutoHideAgentLogSwitch"
            )
        }
    }

    /// Android's Advanced rows, each editing only its own bundled system-prompt override.
    private var advancedSection: some View {
        AndroidPreferenceSection(
            title: String(localized: "ai_advanced_category", defaultValue: "Advanced"),
            palette: surfacePalette
        ) {
            preferenceAction(
                key: "custom_agent_system_prompt",
                title: String(
                    localized: "custom_agent_system_prompt_title",
                    defaultValue: "Agent system prompt"
                ),
                summary: systemPromptSummary(agentSystemPrompt),
                identifier: "aiAgentSystemPromptPreference"
            ) { activeDialog = .systemPrompt(kind: .agent, currentValue: agentSystemPrompt) }
            preferenceDivider
            preferenceAction(
                key: "custom_text_transform_system_prompt",
                title: String(
                    localized: "custom_text_transform_system_prompt_title",
                    defaultValue: "Text transformation system prompt"
                ),
                summary: systemPromptSummary(transformationSystemPrompt),
                identifier: "aiTransformationSystemPromptPreference"
            ) {
                activeDialog = .systemPrompt(kind: .transformation, currentValue: transformationSystemPrompt)
            }
        }
    }

    /// Android's Usage rows with nonselectable totals, reset/retention dialogs, and log destination.
    private var usageSection: some View {
        AndroidPreferenceSection(
            title: String(localized: "ai_usage_category", defaultValue: "Usage"),
            palette: surfacePalette
        ) {
            AndroidCatalogValuePreferenceRow(
                title: String(localized: "llm_usage_summary_title", defaultValue: "Token usage"),
                summary: usageSummary,
                detail: nil,
                icon: aiPreferenceIcon("llm_usage_summary"),
                trailingValue: nil,
                palette: surfacePalette,
                accessibilityIdentifier: "aiUsageSummary"
            )
            preferenceDivider
            preferenceAction(
                key: "llm_reset_usage",
                title: String(localized: "llm_reset_usage_title", defaultValue: "Reset usage data"),
                summary: String(
                    localized: "llm_reset_usage_summary",
                    defaultValue: "Clear cumulative token and cost tracking"
                ),
                identifier: "aiResetUsagePreference"
            ) { activeDialog = .resetUsage }
            preferenceDivider
            preferenceAction(
                key: "raw_log_history",
                title: String(localized: "raw_log_history_title", defaultValue: "AI Log History"),
                summary: String(
                    localized: "raw_log_history_summary",
                    defaultValue: "View and manage saved AI conversation logs"
                ),
                identifier: "aiRawLogHistoryLink"
            ) { activeActivity = .rawLogHistory }
            preferenceDivider
            preferenceAction(
                key: "raw_log_retention",
                title: String(localized: "raw_log_retention_title", defaultValue: "Auto-delete old logs"),
                summary: rawLogRetentionSummary,
                identifier: "aiRawLogRetentionPreference"
            ) { activeDialog = .rawLogRetention(rawLogRetentionDays) }
        }
    }

    /// Shared inset divider used between AI preference rows.
    private var preferenceDivider: some View {
        AndroidPreferenceDivider(palette: surfacePalette)
    }

    /** Builds one shared Android action preference from the canonical AI icon catalog. */
    private func preferenceAction(
        key: String,
        title: String,
        summary: String?,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidCatalogActionPreferenceRow(
            title: title,
            summary: summary,
            icon: aiPreferenceIcon(key),
            palette: surfacePalette,
            accessibilityIdentifier: identifier,
            action: action
        )
    }

    /// Returns exact Android drawable metadata for one AI connection preference key.
    private func aiPreferenceIcon(_ key: String) -> AndBibleIcon? {
        AndBibleIconCatalog.settingsIcon(forAndroidKey: key)
    }

    /** Returns through the explicit AI Settings owner or SwiftUI dismissal fallback. */
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
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

/** App-owned provider list with Android's blank empty state and toolbar Add action. */
private struct AIProvidersView: View {
    /// Pops the provider activity for standalone callers.
    @Environment(\.dismiss) private var dismiss
    /// Current appearance used by the shared overflow surface.
    @Environment(\.colorScheme) private var colorScheme
    /// SwiftData context used to read the durable disclaimer gate.
    @Environment(\.modelContext) private var modelContext
    /// Live provider rows keep the list current after pushed editor changes.
    @Query private var providerConfigurations: [LLMProviderConfig]

    /// Device-only credential boundary forwarded to provider editors.
    let credentialStore: AICredentialStore
    /// Reader/workspace palette inherited from Connection settings.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up action returning to Connection settings.
    let onBack: (() -> Void)?

    /// Android dialog currently presented over the Providers screen.
    @State private var activeDialog: AIConfigurationDialog?
    /// Credential-free persistence failure text.
    @State private var failureMessage: String?
    /// Whether Android's app-owned provider overflow popup is visible.
    @State private var showsOverflowMenu = false

    /** Creates the app-owned Providers activity without reading credentials. */
    init(
        credentialStore: AICredentialStore,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.credentialStore = credentialStore
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    /// Providers in Android's persisted display order.
    private var providers: [LLMProviderConfig] {
        providerConfigurations.sorted {
            if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        AndroidActivityScreen(
            title: String(localized: "ai_providers_category", defaultValue: "Providers"),
            accessibilityIdentifier: "aiProvidersTopAppBar",
            palette: surfacePalette,
            onBack: performBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityAddCircle"),
                accessibilityLabel: String(localized: "ai_add_provider", defaultValue: "Add provider"),
                accessibilityIdentifier: "aiAddProviderLink",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: requestAddProvider
            )
            .disabled(activeDialog != nil)

            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "aiProvidersOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                showsOverflowMenu.toggle()
            }
            .androidPopupMenuAnchor(id: "aiProvidersOverflowAnchor")
            .disabled(activeDialog != nil)
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            AndroidPreferenceDivider(palette: surfacePalette)
                        }
                        AndroidCatalogActionPreferenceRow(
                            title: provider.displayName,
                            summary: credentialSummary(for: provider.id),
                            icon: AndBibleIconCatalog.settingsIcon(
                                forAndroidKey: "ai_providers_shortcut"
                            ),
                            palette: surfacePalette,
                            accessibilityIdentifier: "aiProviderRow_\(provider.id.uuidString)"
                        ) {
                            activeDialog = .providerEditor(
                                providerID: provider.id,
                                providerType: provider.provider
                            )
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .disabled(activeDialog != nil || showsOverflowMenu)
        }
        .androidAccessibilityIdentityMarker(
            label: String(localized: "ai_providers_category", defaultValue: "Providers"),
            accessibilityIdentifier: "aiProvidersScreen",
            surfaceColor: surfacePalette.backgroundColor
        )
        .androidAnchoredPopupMenu(
            anchorID: "aiProvidersOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 220,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "aiProvidersOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiProvidersOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "help", defaultValue: "Help"),
                    icon: .asset("DrawerHelp"),
                    accessibilityIdentifier: "aiProvidersHelpMenuItem"
                ) {
                    showsOverflowMenu = false
                    activeDialog = .help(.aiProviders)
                }
            }
        }
        .aiConfigurationDialog(
            $activeDialog,
            credentialStore: credentialStore
        )
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
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

    /** Returns through the explicit Connection settings owner or environment fallback. */
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }
}
