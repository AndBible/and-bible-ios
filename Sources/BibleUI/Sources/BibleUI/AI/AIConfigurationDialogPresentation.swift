// AIConfigurationDialogPresentation.swift -- Android AI configuration dialogs

import BibleCore
import SwiftData
import SwiftUI

/** Dialog states used by Android's disclaimer-protected AI configuration workflows. */
enum AIConfigurationDialog: Equatable {
    /// Android's typed, app-owned `CommonUtils.showHelpDialog` contract.
    case help(AndroidFeatureHelpTopic)
    /// Read-only responsibility notice opened from Connection settings.
    case disclaimerInformation
    /// One-time acceptance gate retaining the exact requested action.
    case disclaimerAcceptance(AIConfigurationEntryRequest)
    /// Recommended provider and model selection.
    case quickSetupProvider
    /// API-key entry for one recommended setup.
    case quickSetupCredential(AIRecommendedSetup)
    /// Successful Quick Setup acknowledgement.
    case quickSetupComplete
    /// Provider-type selection opened from the Providers screen.
    case providerType
    /// New or existing provider configuration.
    case providerEditor(providerID: UUID?, providerType: LLMProvider)
    /// Provider deletion confirmation shown after the editor closes.
    case providerDeleteConfirmation(providerID: UUID, displayName: String)
    /// Android's response-language single-choice dialog.
    case responseLanguage(currentCode: String?)
    /// Android's secondary free-form language editor.
    case customResponseLanguage(currentValue: String?)
    /// Android's global permission-mode list dialog.
    case permissionMode(AIPermissionMode)
    /// Android's uncapped commentary response-limit editor.
    case commentaryResponseLimit(Int)
    /// Android's uncapped maximum-agent-iterations editor.
    case maximumAgentIterations(Int)
    /// One independently editable Android system prompt.
    case systemPrompt(kind: AISystemPromptKind, currentValue: String?)
    /// Cumulative token-usage reset confirmation.
    case resetUsage
    /// Android's nullable raw-log retention editor.
    case rawLogRetention(Int?)

    /**
     Resolves the first dialog for a protected Android configuration action.

     - Parameters:
       - request: Quick Setup or Add Provider.
       - isDisclaimerAccepted: Durable one-time acceptance state.
     - Returns: The acceptance dialog when required, otherwise the requested first dialog.
     - Side effects: None.
     - Failure modes: None.
     */
    static func initial(
        for request: AIConfigurationEntryRequest,
        isDisclaimerAccepted: Bool
    ) -> Self {
        switch AIDisclaimerGate.decision(for: request, isAccepted: isDisclaimerAccepted) {
        case .proceed(let acceptedRequest):
            return destination(for: acceptedRequest)
        case .requireAcceptance(let pendingRequest):
            return .disclaimerAcceptance(pendingRequest)
        }
    }

    /** Returns the first post-acceptance dialog for one protected action. */
    static func destination(for request: AIConfigurationEntryRequest) -> Self {
        switch request {
        case .quickSetup: return .quickSetupProvider
        case .addProvider: return .providerType
        }
    }

    /**
     Returns whether Android permits a scrim tap to cancel the represented dialog.

     - Returns: `true` only for informational feature Help; configuration and destructive workflows
       remain blocking until an explicit action is selected.
     - Side effects: none.
     - Failure modes: none.
     */
    var allowsOutsideDismissal: Bool {
        if case .help = self {
            return true
        }
        return false
    }
}

/**
 Blocking, app-owned overlay for Android's AI `AlertDialog` workflows.

 The underlying screen remains visible and dimmed while the active dialog owns interaction. Dialog
 transitions replace the panel in place, matching Android's chained setup and provider workflows.
 */
private struct AIConfigurationDialogOverlay: View {
    /// SwiftData context used to commit disclaimer acceptance and provider deletion.
    @Environment(\.modelContext) private var modelContext
    /// Current appearance used for Android's dimmer opacity.
    @Environment(\.colorScheme) private var colorScheme

    /// Parent-owned active dialog state.
    @Binding var dialog: AIConfigurationDialog?
    /// Device-local provider credential boundary.
    let credentialStore: AICredentialStore
    /// Parent refresh callback after provider mutations.
    let onChanged: () -> Void

    /// Credential-free persistence failure text for Connection preference dialogs.
    @State private var failureMessage: String?

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiConfigurationDialogOverlay",
            allowsOutsideDismissal: dialog?.allowsOutsideDismissal ?? false,
            onOutsideTap: dismissDialog
        ) {
            dialogContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(20)
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Renders the exact dialog represented by the parent-owned workflow state. */
    @ViewBuilder
    private var dialogContent: some View {
        switch dialog {
        case .help(let topic):
            AndroidFeatureHelpDialogContent(topic: topic, onDismiss: dismissDialog)
        case .disclaimerInformation:
            AIDisclaimerDialog(mode: .information, onCancel: dismissDialog)
        case .disclaimerAcceptance(let request):
            AIDisclaimerDialog(
                mode: .acceptance,
                onCancel: dismissDialog,
                onAccept: { acceptDisclaimer(for: request) }
            )
        case .quickSetupProvider:
            AIQuickSetupProviderDialog(
                onSelect: { dialog = .quickSetupCredential($0) },
                onCancel: dismissDialog
            )
        case .quickSetupCredential(let option):
            AIQuickSetupCredentialDialog(
                option: option,
                credentialStore: credentialStore,
                onCancel: dismissDialog,
                onSaved: {
                    onChanged()
                    dialog = .quickSetupComplete
                }
            )
        case .quickSetupComplete:
            AIQuickSetupCompleteDialog(onDone: dismissDialog)
        case .providerType:
            AIProviderTypeDialog(
                onSelect: { dialog = .providerEditor(providerID: nil, providerType: $0) },
                onCancel: dismissDialog
            )
        case .providerEditor(let providerID, let providerType):
            AIProviderSettingsDialog(
                providerID: providerID,
                initialProviderType: providerType,
                credentialStore: credentialStore,
                onCancel: dismissDialog,
                onSaved: {
                    onChanged()
                    dismissDialog()
                },
                onRequestDelete: { id, name in
                    dialog = .providerDeleteConfirmation(providerID: id, displayName: name)
                }
            )
        case .providerDeleteConfirmation(let providerID, let displayName):
            AIProviderDeleteConfirmationDialog(
                providerID: providerID,
                displayName: displayName,
                credentialStore: credentialStore,
                onCancel: dismissDialog,
                onDeleted: {
                    onChanged()
                    dismissDialog()
                }
            )
        case .responseLanguage(let currentCode):
            AIResponseLanguageDialog(
                currentCode: currentCode,
                onSelect: { code in
                    saveGlobalSettings { $0.aiLanguage = code }
                },
                onCustom: { dialog = .customResponseLanguage(currentValue: currentCode) },
                onCancel: dismissDialog
            )
        case .customResponseLanguage(let currentValue):
            AICustomLanguageDialog(
                currentValue: currentValue,
                onSave: { value in
                    saveGlobalSettings { $0.aiLanguage = value }
                },
                onCancel: dismissDialog
            )
        case .permissionMode(let currentMode):
            AIPermissionModeDialog(
                currentMode: currentMode,
                onSelect: { mode in
                    saveGlobalSettings { $0.agentPermissionMode = mode }
                },
                onCancel: dismissDialog
            )
        case .commentaryResponseLimit(let currentValue):
            AINumericSettingDialog(
                title: String(
                    localized: "commentary_max_response_dialog_title",
                    defaultValue: "Set maximum response size (tokens)"
                ),
                message: String(
                    localized: "commentary_max_response_dialog_message",
                    defaultValue: "When the AI fetches commentaries and the total response exceeds this token limit, a selection dialog lets you choose which commentaries to send to the AI.\n\n0 = no limit (all commentaries are sent automatically)."
                ),
                currentValue: currentValue,
                invalidFallback: 0,
                minimum: 0,
                onSave: { value in
                    saveGlobalSettings { $0.commentaryMaxResponseTokens = value }
                },
                onCancel: dismissDialog
            )
        case .maximumAgentIterations(let currentValue):
            AINumericSettingDialog(
                title: String(localized: "agent_max_iterations_title", defaultValue: "Max agent iterations"),
                message: String(
                    localized: "agent_max_iterations_summary",
                    defaultValue: "Maximum iterations before asking to continue (0 = unlimited)"
                ),
                currentValue: currentValue,
                invalidFallback: 10,
                minimum: 0,
                onSave: { value in
                    saveGlobalSettings { $0.maxIterations = value }
                },
                onCancel: dismissDialog
            )
        case .systemPrompt(let kind, let currentValue):
            AISystemPromptDialog(
                kind: kind,
                currentValue: currentValue,
                onSave: { value in
                    saveGlobalSettings { settings in
                        switch kind {
                        case .agent: settings.customAgentSystemPrompt = value
                        case .transformation: settings.customTextTransformationSystemPrompt = value
                        }
                    }
                },
                onCancel: dismissDialog
            )
        case .resetUsage:
            AIResetUsageDialog(
                onConfirm: resetUsage,
                onCancel: dismissDialog
            )
        case .rawLogRetention(let currentDays):
            AIRawLogRetentionDialog(
                currentDays: currentDays,
                onSave: { days in
                    saveGlobalSettings { $0.rawLogRetentionDays = days }
                },
                onCancel: dismissDialog
            )
        case nil:
            EmptyView()
        }
    }

    /** Clears the active dialog without mutating configuration or acceptance state. */
    private func dismissDialog() {
        dialog = nil
    }

    /**
     Commits one Android Connection preference and refreshes the underlying summary rows.

     - Parameter mutation: In-place mutation applied to the singleton global settings row.
     - Side effects: Mutates SwiftData, saves once, invokes `onChanged`, and dismisses on success.
     - Failure modes: Persistence errors retain the active dialog and show credential-free copy.
     */
    private func saveGlobalSettings(_ mutation: (GlobalAISettings) -> Void) {
        do {
            let store = AISettingsStore(modelContext: modelContext)
            mutation(try store.globalSettings())
            try store.save()
            onChanged()
            dismissDialog()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Zeros Android-compatible cumulative usage rows without deleting their aggregation identities.

     - Side effects: Mutates every usage row, saves once, refreshes Connection, and dismisses.
     - Failure modes: Persistence errors leave the confirmation visible with localized error copy.
     */
    private func resetUsage() {
        do {
            let store = AISettingsStore(modelContext: modelContext)
            for row in try store.usageRecords() {
                row.inputTokens = 0
                row.outputTokens = 0
                row.cacheCreationTokens = 0
                row.cacheReadTokens = 0
                row.estimatedCostUSD = 0
            }
            try store.save()
            onChanged()
            dismissDialog()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Persists one-time disclaimer acceptance before advancing the same dialog workflow.

     - Parameter request: Protected action retained by the acceptance dialog.
     - Returns: Localized failure text, or `nil` after commit and transition.
     - Side effects: Saves `aiDisclaimerAccepted` and replaces the active dialog on success.
     - Failure modes: Persistence errors leave acceptance visible and return credential-free copy.
     */
    private func acceptDisclaimer(for request: AIConfigurationEntryRequest) -> String? {
        do {
            try AISettingsStore(modelContext: modelContext).setDisclaimerAccepted(true)
            dialog = AIConfigurationDialog.destination(for: request)
            return nil
        } catch {
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Shared presenter for Android's app-owned AI dialog workflows. */
extension View {
    /**
     Presents one blocking AI configuration dialog above the receiving screen.

     - Parameters:
       - dialog: Parent-owned dialog state, or `nil` when no dialog is visible.
       - credentialStore: Device-local Keychain boundary used by provider forms.
       - onChanged: Callback after a committed provider mutation.
     - Returns: The receiving screen with an optional Android-style dialog overlay.
     - Side effects: Dialog actions may mutate SwiftData and Keychain through their explicit stores.
     - Failure modes: Dialog-level failures remain visible without dismissing the owning screen.
     */
    func aiConfigurationDialog(
        _ dialog: Binding<AIConfigurationDialog?>,
        credentialStore: AICredentialStore,
        onChanged: @escaping () -> Void = {}
    ) -> some View {
        self
            .accessibilityHidden(dialog.wrappedValue != nil)
            .disabled(dialog.wrappedValue != nil)
            .aiConfigurationNavigationLocked(dialog.wrappedValue != nil)
            .overlay {
                if dialog.wrappedValue != nil {
                    AIConfigurationDialogOverlay(
                        dialog: dialog,
                        credentialStore: credentialStore,
                        onChanged: onChanged
                    )
                }
            }
    }

    /** Prevents inherited navigation Back from escaping an Android-modal dialog. */
    @ViewBuilder
    fileprivate func aiConfigurationNavigationLocked(_ locked: Bool) -> some View {
        #if os(iOS)
        navigationBarBackButtonHidden(locked)
        #else
        self
        #endif
    }
}

/** Compatibility name that resolves directly to the application's shared Android dialog scaffold. */
typealias AIAndroidDialogSurface<Content: View, Actions: View> =
    AndroidDialogScaffold<Content, Actions>

/** Compatibility name that resolves directly to the application's shared Android text action. */
typealias AIAndroidDialogAction = AndroidDialogTextAction

/** Android's informational and one-time acceptance variants of the AI disclaimer dialog. */
private struct AIDisclaimerDialog: View {
    /// Current appearance used by the shared AppCompat dialog marker.
    @Environment(\.colorScheme) private var colorScheme

    /// Information or explicit acceptance behavior.
    enum Mode {
        case information
        case acceptance
    }

    /// Dialog behavior.
    let mode: Mode
    /// Negative or positive dismissal callback.
    let onCancel: () -> Void
    /// Durable acceptance callback used only by acceptance mode.
    var onAccept: (() -> String?)?

    /// Credential-free persistence failure returned by the acceptance callback.
    @State private var failureMessage: String?

    /**
     Builds Android's scrollable disclaimer content and information/acceptance actions.

     The scroll container has its own semantic identity because the dialog-level identity is a
     noninteractive sibling marker. Accessibility automation and assistive interaction must scroll
     the visible content rather than attempting gestures on that marker.

     - Returns: Shared Android dialog content for the selected disclaimer mode.
     - Side effects: Cancel invokes `onCancel`; acceptance invokes `onAccept` and may expose a
       credential-free persistence error dialog.
     - Failure modes: A persistence error leaves the disclaimer visible and presents localized
       error copy without treating the disclaimer as accepted.
     */
    var body: some View {
        AIAndroidDialogSurface(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(AIDisclaimerCopy.localized().segments.enumerated()), id: \.offset) { _, segment in
                        disclaimerSegment(segment)
                    }

                    if mode == .acceptance {
                        Button {
                            failureMessage = onAccept?()
                        } label: {
                            Text(
                                String(
                                    localized: "ai_disclaimer_accept_button",
                                    defaultValue: "I accept and take full responsibility"
                                )
                            )
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aiDisclaimerAcceptButton")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: mode == .acceptance ? 600 : 520)
            .accessibilityIdentifier("aiDisclaimerScrollView")
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: mode == .acceptance
                    ? String(localized: "cancel", defaultValue: "Cancel")
                    : String(localized: "okay", defaultValue: "OK"),
                action: onCancel
            )
            .accessibilityIdentifier(
                mode == .acceptance ? "aiDisclaimerCancelButton" : "aiDisclaimerOKButton"
            )
        }
        .androidAccessibilityIdentityMarker(
            label: title,
            accessibilityIdentifier: "aiDisclaimerScreen",
            surfaceColor: AndroidDialogSurfacePalette.background(for: colorScheme)
        )
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /// Android's distinct title for informational and acceptance dialogs.
    private var title: String {
        switch mode {
        case .information:
            return String(
                localized: "ai_disclaimer_dialog_title",
                defaultValue: "AI Tools — Important Information"
            )
        case .acceptance:
            return String(
                localized: "ai_disclaimer_accept_title",
                defaultValue: "Accept AI Disclaimer"
            )
        }
    }

    /** Renders one ordered segment from Android's disclaimer composition. */
    @ViewBuilder
    private func disclaimerSegment(_ segment: AIDisclaimerSegment) -> some View {
        switch segment.style {
        case .body:
            Text(segment.text)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•")
                Text(segment.text)
            }
        case .italic:
            Text(segment.text).italic()
        }
    }
}

/** Android's provider-type AlertDialog, including the unsupported-provider checkbox. */
private struct AIProviderTypeDialog: View {
    /// Persisted provider rows used to hide duplicate known-provider types.
    @Query private var providerConfigurations: [LLMProviderConfig]

    /// Current appearance used by the shared AppCompat dialog marker.
    @Environment(\.colorScheme) private var colorScheme

    /// Selected provider callback.
    let onSelect: (LLMProvider) -> Void
    /// Negative action callback.
    let onCancel: () -> Void

    /// Whether Android's community provider tier is included.
    @State private var showsUnsupportedProviders = false

    /// Android's recommended tier in display order.
    private let recommendedProviders: [LLMProvider] = [.gemini, .openAI, .anthropic, .openRouter]
    /// Android's remaining community and custom provider tier.
    private let unsupportedProviders: [LLMProvider] = [
        .xAI, .mistral, .deepSeek, .groq, .alibaba, .custom,
    ]

    /// Provider types available after Android's duplicate filtering.
    private var availableProviders: Set<LLMProvider> {
        let existing = Set(providerConfigurations.map(\.provider))
        return Set(LLMProvider.allCases.filter { $0 == .custom || !existing.contains($0) })
    }

    var body: some View {
        AIAndroidDialogSurface(
            title: String(localized: "ai_provider_select_type", defaultValue: "Select provider type")
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if unsupportedProviders.contains(where: availableProviders.contains) {
                        Button {
                            showsUnsupportedProviders.toggle()
                        } label: {
                            HStack(spacing: 10) {
                                Image(
                                    systemName: showsUnsupportedProviders
                                        ? "checkmark.square"
                                        : "square"
                                )
                                Text(
                                    String(
                                        localized: "show_also_unsupported_providers",
                                        defaultValue: "Show also unsupported providers"
                                    )
                                )
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }

                    providerTier(
                        String(localized: "ai_provider_tier_recommended", defaultValue: "Recommended"),
                        providers: recommendedProviders.filter(availableProviders.contains)
                    )

                    if showsUnsupportedProviders {
                        providerTier(
                            String(
                                localized: "ai_provider_tier_community",
                                defaultValue: "Other providers (not tested)"
                            ),
                            providers: unsupportedProviders.filter(availableProviders.contains)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 500)
        } actions: {
            Spacer()
            AIAndroidDialogAction(
                title: String(localized: "cancel", defaultValue: "Cancel"),
                action: onCancel
            )
            .accessibilityIdentifier("aiProviderTypeCancelButton")
        }
        .androidAccessibilityIdentityMarker(
            label: String(localized: "ai_provider_select_type", defaultValue: "Select provider type"),
            accessibilityIdentifier: "aiProviderTypeSelectionScreen",
            surfaceColor: AndroidDialogSurfacePalette.background(for: colorScheme)
        )
    }

    /** Builds one Android provider tier with non-selectable heading and selectable rows. */
    @ViewBuilder
    private func providerTier(_ title: String, providers: [LLMProvider]) -> some View {
        if !providers.isEmpty {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(providers, id: \.self) { provider in
                Button {
                    onSelect(provider)
                } label: {
                    Text(AIProviderPresentation.displayName(for: provider))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aiProviderType_\(provider.rawValue)")

                Divider()
            }
        }
    }
}
