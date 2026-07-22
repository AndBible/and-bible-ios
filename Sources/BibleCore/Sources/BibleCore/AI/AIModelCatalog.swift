import Foundation

/**
 Android-compatible pricing metadata for one provider model.

 Prices are US dollars per million tokens. The cache prices mirror Android's `ModelPricing`
 defaults when a dynamic endpoint reports only prompt and completion rates.
 */
public struct AIModelPricing: Codable, Equatable, Sendable {
    /// Input-token price in US dollars per million tokens.
    public let inputPerMillion: Double
    /// Output-token price in US dollars per million tokens.
    public let outputPerMillion: Double
    /// Cache-creation price in US dollars per million tokens.
    public let cacheCreationPerMillion: Double
    /// Cache-read price in US dollars per million tokens.
    public let cacheReadPerMillion: Double
    /// Whether Android allows this model to submit AI bug reports.
    public let supported: Bool

    /**
     Creates immutable pricing metadata using Android's cache-price defaults.

     - Parameters:
       - inputPerMillion: Input-token rate in US dollars per million tokens.
       - outputPerMillion: Output-token rate in US dollars per million tokens.
       - cacheCreationPerMillion: Explicit cache-creation rate, or the input rate when omitted.
       - cacheReadPerMillion: Explicit cache-read rate, or ten percent of the input rate when omitted.
       - supported: Whether Android marks this model as supported for bug reporting.
     - Side effects: None.
     - Failure modes: Values are retained verbatim; callers validate user or network values before
       constructing pricing.
     */
    public init(
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheCreationPerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil,
        supported: Bool = false
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheCreationPerMillion = cacheCreationPerMillion ?? inputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion ?? inputPerMillion * 0.1
        self.supported = supported
    }

    /// Combined input/output price used by Android's add-model ordering.
    public var selectionSortPrice: Double {
        inputPerMillion + outputPerMillion
    }
}

/**
 One model offered by Android's add-model dialog.

 Instances come from either the built-in `LlmProvider` catalog or a credential-free dynamic cache.
 The model identifier is the exact value sent to the provider.
 */
public struct AIAvailableModel: Codable, Equatable, Identifiable, Sendable {
    /// Provider model identifier and stable selection identity.
    public let id: String
    /// Provider-supplied display name; Android currently displays `id` in model selectors.
    public let name: String
    /// Known provider or dynamic pricing, or `nil` when users must supply custom rates.
    public let pricing: AIModelPricing?

    /**
     Creates a selectable model without performing persistence or network work.

     - Parameters:
       - id: Exact provider model identifier.
       - name: Provider display name, normally the identifier when unavailable.
       - pricing: Known per-million-token rates, if supplied by a trusted catalog or endpoint.
     - Side effects: None.
     - Failure modes: None; callers reject blank identifiers before construction.
     */
    public init(id: String, name: String, pricing: AIModelPricing?) {
        self.id = id
        self.name = name
        self.pricing = pricing
    }

    /// Prefix before the first slash, such as `anthropic` in an OpenRouter model identifier.
    public var category: String {
        guard let slash = id.firstIndex(of: "/") else { return "" }
        return String(id[..<slash])
    }
}

/**
 Android's current-stable built-in model catalog and model-selection policy.

 The entries, prices, support flags, dynamic-provider capabilities, category behavior, and lookup
 rules mirror `service/llm/LlmUtils.kt` and `view/activity/ai/ModelDialogs.kt`.
 */
public enum AIModelCatalog {
    /// Exact Android provider model entries in declaration order.
    private static let modelsByProvider: [LLMProvider: [AIAvailableModel]] = [
        .gemini: [
            model("gemini-3-flash-preview", 0.50, 3.00, supported: true),
            model("gemini-3.1-pro-preview", 2.00, 12.00, 2.00, 0.20, supported: true),
            model("gemini-2.5-pro", 1.25, 10.00, 1.25, 0.3125, supported: true),
            model("gemini-2.5-flash", 0.15, 0.60, 0.15, 0.0375, supported: true),
        ],
        .openAI: [
            model("gpt-5.4-mini", 0.75, 4.50, 0.75, 0.075, supported: true),
            model("gpt-5.4", 2.50, 15.00, 2.50, 0.25, supported: true),
            model("gpt-5-mini", 0.40, 1.60, 0.40, 0.10),
            model("gpt-5-nano", 0.10, 0.40, 0.10, 0.025),
            model("gpt-5.2", 2.00, 8.00, 2.00, 0.50),
            model("gpt-4o-mini", 0.15, 0.60, 0.15, 0.075),
        ],
        .anthropic: [
            model("claude-haiku-4-5", 0.80, 4.00, 1.00, 0.08, supported: true),
            model("claude-sonnet-4-6", 3.00, 15.00, 3.75, 0.30, supported: true),
            model("claude-opus-4-6", 15.00, 75.00, 18.75, 1.50, supported: true),
        ],
        .xAI: [
            model("grok-4-0709", 3.00, 15.00),
            model("grok-4-1-fast-reasoning", 3.00, 15.00),
            model("grok-3-mini", 0.30, 0.50),
        ],
        .mistral: [
            model("mistral-small-latest", 0.10, 0.30),
            model("mistral-large-latest", 2.00, 6.00),
        ],
        .deepSeek: [
            model("deepseek-chat", 0.27, 1.10, 0.27, 0.07),
            model("deepseek-reasoner", 0.55, 2.19, 0.55, 0.14),
        ],
        .groq: [
            model("llama-3.3-70b-versatile", 0.59, 0.79),
            model("openai/gpt-oss-120b", 0.30, 0.60),
            model("llama-3.1-8b-instant", 0.05, 0.08),
        ],
        .alibaba: [
            model("qwen-plus", 0.80, 2.00),
            model("qwen-turbo", 0.30, 0.60),
            model("qwen3-max", 1.60, 6.40),
        ],
        .openRouter: [
            AIAvailableModel(id: "anthropic/claude-sonnet-4", name: "anthropic/claude-sonnet-4", pricing: nil),
            AIAvailableModel(id: "google/gemini-3-flash", name: "google/gemini-3-flash", pricing: nil),
            AIAvailableModel(id: "openai/gpt-5.4-mini", name: "openai/gpt-5.4-mini", pricing: nil),
        ],
        .custom: [],
    ]

    /**
     Returns Android's built-in entries for one provider in declaration order.

     - Parameter provider: Known provider type or Custom.
     - Returns: Immutable model entries; Custom returns an empty list.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func models(for provider: LLMProvider) -> [AIAvailableModel] {
        modelsByProvider[provider] ?? []
    }

    /**
     Chooses Android's dynamic-cache result or built-in fallback for an add-model dialog.

     - Parameters:
       - provider: Provider whose catalog is being displayed.
       - cachedModels: Previously fetched non-secret entries, or `nil` when no valid cache exists.
     - Returns: A non-empty dynamic cache for capable providers; otherwise built-in entries.
     - Side effects: None.
     - Failure modes: Empty dynamic caches are ignored so a failed endpoint cannot hide fallbacks.
     */
    public static func availableModels(
        for provider: LLMProvider,
        cachedModels: [AIAvailableModel]?
    ) -> [AIAvailableModel] {
        if supportsDynamicModels(provider), let cachedModels, !cachedModels.isEmpty {
            return cachedModels
        }
        return models(for: provider)
    }

    /**
     Filters and price-sorts one add-model list like Android's `updateModelSpinner`.

     - Parameters:
       - models: Dynamic or built-in candidates.
       - category: Optional slash-prefix category; comparison is case-insensitive.
       - includesUnsupported: Whether models without Android's supported flag remain visible.
     - Returns: Matching models sorted by combined input/output price, with unknown prices last and
       source order retained for equal prices.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func selectableModels(
        from models: [AIAvailableModel],
        category: String?,
        includesUnsupported: Bool
    ) -> [AIAvailableModel] {
        let filtered = models.filter { model in
            let matchesCategory = category == nil
                || model.category.caseInsensitiveCompare(category ?? "") == .orderedSame
            return matchesCategory && (includesUnsupported || isSupported(model.id))
        }
        return filtered.enumerated().sorted { lhs, rhs in
            let leftPrice = lhs.element.pricing?.selectionSortPrice ?? .greatestFiniteMagnitude
            let rightPrice = rhs.element.pricing?.selectionSortPrice ?? .greatestFiniteMagnitude
            return leftPrice == rightPrice ? lhs.offset < rhs.offset : leftPrice < rightPrice
        }.map(\.element)
    }

    /**
     Returns raw slash-prefix categories using Android's case-sensitive `distinct().sorted()` order.

     - Parameter models: Dynamic or built-in candidates.
     - Returns: Distinct non-empty category identifiers suitable for filtering.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func categories(in models: [AIAvailableModel]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let category = model.category
            guard !category.isEmpty, seen.insert(category).inserted else { return nil }
            return category
        }.sorted()
    }

    /**
     Returns whether Android initially includes unsupported entries for a candidate list.

     Android hides unsupported models when at least one supported choice exists. Lists containing no
     supported entries remain fully visible so community and custom providers are still usable.
     */
    public static func initiallyIncludesUnsupported(in models: [AIAvailableModel]) -> Bool {
        !models.contains { isSupported($0.id) }
    }

    /** Returns whether Android shows its unsupported-model checkbox for a mixed candidate list. */
    public static func showsUnsupportedToggle(in models: [AIAvailableModel]) -> Bool {
        let hasSupported = models.contains { isSupported($0.id) }
        let hasUnsupported = models.contains { !isSupported($0.id) }
        return hasSupported && hasUnsupported
    }

    /**
     Resolves trusted pricing using Android's exact-ID then slash-prefix-stripped lookup.

     - Parameters:
       - modelID: Exact provider model identifier.
       - dynamicModels: Optional cached entries whose endpoint-supplied pricing participates after
         the built-in catalog.
     - Returns: Trusted pricing, or `nil` when custom rates remain editable.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func pricing(
        for modelID: String,
        dynamicModels: [AIAvailableModel] = []
    ) -> AIModelPricing? {
        builtInPricing(for: modelID)
            ?? dynamicModels.first(where: { $0.id == modelID })?.pricing
    }

    /** Returns whether built-in or dynamic pricing makes a model's prices read-only. */
    public static func isKnownModel(
        _ modelID: String,
        dynamicModels: [AIAvailableModel] = []
    ) -> Bool {
        pricing(for: modelID, dynamicModels: dynamicModels) != nil
    }

    /**
     Returns Android's supported badge state, including OpenRouter-style stripped identifiers.

     Dynamic endpoint metadata cannot independently grant support; only the built-in catalog's flag
     controls bug-report eligibility.
     */
    public static func isSupported(_ modelID: String) -> Bool {
        builtInPricing(for: modelID)?.supported == true
    }

    /// Whether Android fetches this provider's OpenAI-compatible `/models` endpoint.
    public static func supportsDynamicModels(_ provider: LLMProvider) -> Bool {
        provider != .anthropic && provider != .custom
    }

    /// Whether Android fetches this provider's model endpoint without an API key.
    public static func modelsEndpointIsPublic(_ provider: LLMProvider) -> Bool {
        provider == .openRouter
    }

    /** Resolves built-in pricing using Android's exact and stripped model-ID passes. */
    private static func builtInPricing(for modelID: String) -> AIModelPricing? {
        for provider in LLMProvider.allCases {
            if let pricing = models(for: provider).first(where: { $0.id == modelID })?.pricing {
                return pricing
            }
        }

        guard let slash = modelID.firstIndex(of: "/") else { return nil }
        let stripped = String(modelID[modelID.index(after: slash)...])
        for provider in LLMProvider.allCases {
            if let pricing = models(for: provider).first(where: { $0.id == stripped })?.pricing {
                return pricing
            }
        }
        return nil
    }

    /** Builds one built-in entry while keeping the catalog declaration compact and auditable. */
    private static func model(
        _ id: String,
        _ input: Double,
        _ output: Double,
        _ cacheCreation: Double? = nil,
        _ cacheRead: Double? = nil,
        supported: Bool = false
    ) -> AIAvailableModel {
        AIAvailableModel(
            id: id,
            name: id,
            pricing: AIModelPricing(
                inputPerMillion: input,
                outputPerMillion: output,
                cacheCreationPerMillion: cacheCreation,
                cacheReadPerMillion: cacheRead,
                supported: supported
            )
        )
    }
}
