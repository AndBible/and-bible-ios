// AIConfigurationSupport.swift -- Credential-safe AI setup and usage policy

import BibleCore
import Foundation

/** Secret-free snapshot used to decide whether one provider can execute an AI request. */
public struct AIProviderUsabilitySnapshot: Equatable, Sendable {
    /// Provider configuration identity.
    public let providerID: UUID
    /// Whether the device-only credential store currently contains a non-empty key.
    public let hasCredential: Bool
    /// Configured model identities owned by the provider.
    public let modelIDs: Set<UUID>

    /** Creates an immutable snapshot without retaining the credential itself. */
    public init(providerID: UUID, hasCredential: Bool, modelIDs: Set<UUID>) {
        self.providerID = providerID
        self.hasCredential = hasCredential
        self.modelIDs = modelIDs
    }
}

/** Pure Android-compatible provider and default-model usability decisions. */
public enum AIConfigurationUsability {
    /**
     Returns whether one provider has both prerequisites required for execution.

     A saved provider row alone is never usable. This deliberately prevents settings and reader
     actions from reporting readiness when either the Keychain credential or every model is absent.
     */
    public static func providerIsUsable(_ snapshot: AIProviderUsabilitySnapshot) -> Bool {
        snapshot.hasCredential && !snapshot.modelIDs.isEmpty
    }

    /** Returns whether the selected default model belongs to a currently usable provider. */
    public static func defaultModelIsUsable(
        defaultModelID: UUID?,
        providers: [AIProviderUsabilitySnapshot]
    ) -> Bool {
        guard let defaultModelID else { return false }
        return providers.contains {
            providerIsUsable($0) && $0.modelIDs.contains(defaultModelID)
        }
    }
}

/** One provider/model pair offered by Android's quick setup workflow. */
public struct AIRecommendedSetup: Identifiable, Equatable, Sendable {
    /// Known provider selected by the workflow.
    public let provider: LLMProvider
    /// Exact model identifier sent to the provider.
    public let modelID: String
    /// Input price in USD per million tokens.
    public let inputPricePerMillion: Double
    /// Output price in USD per million tokens.
    public let outputPricePerMillion: Double
    /// Cache-creation price in USD per million tokens.
    public let cacheCreationPricePerMillion: Double
    /// Cache-read price in USD per million tokens.
    public let cacheReadPricePerMillion: Double

    /// Stable option identity.
    public var id: String { provider.rawValue }

    /** Creates a recommended option with Android's model pricing metadata. */
    public init(
        provider: LLMProvider,
        modelID: String,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cacheCreationPricePerMillion: Double = 0,
        cacheReadPricePerMillion: Double = 0
    ) {
        self.provider = provider
        self.modelID = modelID
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheCreationPricePerMillion = cacheCreationPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
    }
}

/** Current-stable Android quick setup catalog. */
public enum AIRecommendedSetupCatalog {
    /// Exact Android `EasySetupDialogs.kt` provider order, model IDs, and prices.
    public static let options: [AIRecommendedSetup] = [
        AIRecommendedSetup(
            provider: .gemini,
            modelID: "gemini-3-flash-preview",
            inputPricePerMillion: 0.50,
            outputPricePerMillion: 3.00
        ),
        AIRecommendedSetup(
            provider: .anthropic,
            modelID: "claude-haiku-4-5",
            inputPricePerMillion: 0.80,
            outputPricePerMillion: 4.00,
            cacheCreationPricePerMillion: 1.00,
            cacheReadPricePerMillion: 0.08
        ),
        AIRecommendedSetup(
            provider: .openAI,
            modelID: "gpt-5.4-mini",
            inputPricePerMillion: 0.75,
            outputPricePerMillion: 4.50,
            cacheCreationPricePerMillion: 0.75,
            cacheReadPricePerMillion: 0.075
        ),
    ]
}

/** Stable user-visible names for Android's provider enum. */
public enum AIProviderPresentation {
    /** Returns the provider name used by Android's current-stable settings UI. */
    public static func displayName(for provider: LLMProvider) -> String {
        switch provider {
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI (ChatGPT)"
        case .anthropic: return "Anthropic (Claude)"
        case .xAI: return "xAI (Grok)"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .groq: return "Groq"
        case .alibaba: return "Alibaba Qwen"
        case .openRouter: return "OpenRouter"
        case .custom:
            return String(
                localized: "llm_provider_custom",
                defaultValue: "Custom (OpenAI compatible)"
            )
        }
    }
}

/** Android-compatible destructive reset across synced settings and device-only credentials. */
@MainActor
public enum AISettingsResetter {
    /**
     Removes credentials, providers/models/usage, user prompts/categories, and global overrides.

     Raw conversation logs intentionally remain because Android's reset workflow clears settings
     and cumulative usage but exposes log deletion through its separate history screen.

     - Parameters:
       - settingsStore: Synced settings persistence owner.
       - credentialStore: Device-only Keychain owner.
     - Side effects: Deletes Keychain items and mutates SwiftData rows synchronously.
     - Throws: The first credential or persistence failure; no secret value is included.
     */
    public static func reset(
        settingsStore: AISettingsStore,
        credentialStore: AICredentialStore
    ) throws {
        let providers = try settingsStore.providers()
        for provider in providers {
            try credentialStore.removeCredential(for: provider.id)
        }
        for provider in providers {
            try settingsStore.deleteProvider(id: provider.id)
        }
        for prompt in try settingsStore.userPrompts() {
            try settingsStore.deletePrompt(prompt)
        }
        for category in try settingsStore.userCategories() {
            try settingsStore.deleteCategory(id: category.id, deletePrompts: true)
        }

        let settings = try settingsStore.globalSettings()
        let defaults = GlobalAISettings()
        settings.agentPermissionModeRawValue = defaults.agentPermissionModeRawValue
        settings.permanentlyAllowedToolsRawValue = defaults.permanentlyAllowedToolsRawValue
        settings.permanentlyDeniedToolsRawValue = defaults.permanentlyDeniedToolsRawValue
        settings.aiExcludedDocumentsRawValue = defaults.aiExcludedDocumentsRawValue
        settings.commentaryMaxResponseTokens = defaults.commentaryMaxResponseTokens
        settings.hiddenBuiltInPromptsRawValue = defaults.hiddenBuiltInPromptsRawValue
        settings.maxIterations = defaults.maxIterations
        settings.commentaryDeselectedRawValue = defaults.commentaryDeselectedRawValue
        settings.defaultModelId = defaults.defaultModelId
        settings.aiLanguage = defaults.aiLanguage
        settings.askModelBeforeRun = defaults.askModelBeforeRun
        settings.aiDisclaimerAccepted = defaults.aiDisclaimerAccepted
        settings.hiddenBuiltInCategoriesRawValue = defaults.hiddenBuiltInCategoriesRawValue
        settings.customAgentSystemPrompt = defaults.customAgentSystemPrompt
        settings.customTextTransformationSystemPrompt = defaults.customTextTransformationSystemPrompt
        settings.favoritePromptsRawValue = defaults.favoritePromptsRawValue
        settings.rawLogRetentionDays = defaults.rawLogRetentionDays
        settings.autoHideAgentLogOnCompletion = defaults.autoHideAgentLogOnCompletion
        try settingsStore.save()
    }
}

/** Pure usage-price calculation shared by execution persistence and settings summaries. */
public enum AIUsageCostCalculator {
    /**
     Calculates estimated USD cost from provider token counters and configured per-million prices.

     Negative counters and prices contribute zero. A non-finite intermediate result is returned as
     zero so malformed metadata cannot poison cumulative usage rows.
     */
    public static func estimatedCostUSD(
        usage: LLMUsage,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cacheCreationPricePerMillion: Double,
        cacheReadPricePerMillion: Double
    ) -> Double {
        let divisor = 1_000_000.0
        let value = Double(usage.inputTokens) * max(inputPricePerMillion, 0) / divisor
            + Double(usage.outputTokens) * max(outputPricePerMillion, 0) / divisor
            + Double(usage.cacheCreationTokens) * max(cacheCreationPricePerMillion, 0) / divisor
            + Double(usage.cacheReadTokens) * max(cacheReadPricePerMillion, 0) / divisor
        return value.isFinite ? max(value, 0) : 0
    }
}

/** Credential-safe provider connection check used by quick setup and provider editing. */
public struct AIConnectionTester: Sendable {
    /// Provider-neutral HTTP transport.
    private let client: any LLMCompleting

    /** Creates a tester over production or deterministic transport. */
    public init(client: any LLMCompleting = LLMHTTPClient()) {
        self.client = client
    }

    /**
     Performs one minimal authenticated completion against an already resolved model.

     - Parameter model: Transient model tuple whose credential is used only by the HTTP adapter.
     - Returns: `true` after a valid provider response, including an empty response body.
     - Side effects: Performs one cancellable HTTPS request.
     - Throws: Secret-free model-client or cancellation failures.
     */
    public func test(model: ResolvedLLMModel) async throws -> Bool {
        _ = try await client.complete(
            LLMCompletionRequest(
                endpoint: model.endpoint,
                credential: model.credential,
                apiFormat: model.apiFormat,
                model: model.modelId,
                messages: [
                    LLMMessage(role: .user, content: "Reply with OK."),
                ],
                tools: [],
                temperature: 0,
                extraHeaders: model.extraHeaders,
                supportsCacheControl: model.supportsCacheControl
            )
        )
        return true
    }
}
