import Foundation

/**
 Fetches and caches credential-free model metadata from OpenAI-compatible `/models` endpoints.

 Each provider uses a separate seven-day cache containing only model identifiers, display names,
 public pricing, and a fetch timestamp. API keys exist only in a transient request header and are
 never encoded, logged, placed in SwiftData, or included in an error returned to callers.

 - Important: Actor isolation serializes cache memory and file access. Network requests remain
 cancellable through `URLSession.data(for:)`.
 */
public actor AIDynamicModelService {
    /// Shared production service using an ephemeral 30-second URL session and app cache directory.
    public static let shared = AIDynamicModelService(
        session: productionSession(),
        cacheDirectory: productionCacheDirectory()
    )

    /// Android's cache lifetime before a provider endpoint is queried again.
    public static let androidCacheMaximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// HTTP transport; production and tests inject sessions without sharing response caches.
    private let session: URLSession
    /// Directory containing one sanitized JSON cache per provider type.
    private let cacheDirectory: URL
    /// Maximum accepted cache age.
    private let cacheMaximumAge: TimeInterval
    /// Injectable wall clock used by deterministic expiry tests.
    private let now: @Sendable () -> Date
    /// Actor-isolated decoded cache entries keyed only by non-secret provider enum values.
    private var memoryCache: [LLMProvider: CacheEnvelope] = [:]

    /**
     Creates a dynamic model service over explicit transport, storage, and clock dependencies.

     - Parameters:
       - session: URL session used only for provider `/models` requests.
       - cacheDirectory: Directory for sanitized per-provider JSON files.
       - cacheMaximumAge: Freshness interval; defaults to Android's seven days.
       - now: Wall clock used for freshness comparisons and successful fetch timestamps.
     - Side effects: None until cache read, cache write, or fetch methods are called.
     - Failure modes: Invalid cache directories or files are handled as cache misses.
     */
    public init(
        session: URLSession,
        cacheDirectory: URL,
        cacheMaximumAge: TimeInterval = AIDynamicModelService.androidCacheMaximumAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.cacheMaximumAge = cacheMaximumAge
        self.now = now
    }

    /**
     Returns cached models without performing network I/O.

     - Parameter provider: Provider enum used as the non-secret cache key.
     - Returns: A non-empty decoded list, or `nil` when no valid cache exists.
     - Side effects: Lazily reads one cache file and retains its decoded value in actor memory.
     - Failure modes: Missing, unreadable, malformed, or empty cache files are treated as misses.
     */
    public func cachedModels(for provider: LLMProvider) -> [AIAvailableModel]? {
        cacheEnvelope(for: provider)?.models
    }

    /**
     Returns sanitized cached metadata across all provider types in Android declaration order.

     - Returns: Every decoded non-secret model entry, retaining provider and cache ordering.
     - Side effects: Lazily reads each provider's sanitized cache file into actor memory.
     - Failure modes: Missing or invalid provider caches contribute no entries.
     */
    public func cachedModelsAcrossProviders() -> [AIAvailableModel] {
        LLMProvider.allCases.flatMap { provider in
            cacheEnvelope(for: provider)?.models ?? []
        }
    }

    /**
     Returns whether Android would refresh one provider's dynamic model cache.

     - Parameter provider: Provider enum used as the non-secret cache key.
     - Returns: `true` for a missing cache or one older than seven days; future timestamps remain
       fresh until the clock catches up.
     - Side effects: May lazily read one sanitized cache file.
     - Failure modes: Invalid cache files are treated as missing.
     */
    public func needsRefresh(for provider: LLMProvider) -> Bool {
        guard let envelope = cacheEnvelope(for: provider) else { return true }
        return now().timeIntervalSince(envelope.fetchedAt) > cacheMaximumAge
    }

    /**
     Refreshes a capable provider only when its sanitized cache is missing or stale.

     - Parameters:
       - provider: Known provider whose capability flags mirror Android.
       - endpoint: Provider base endpoint; `/models` is appended exactly once.
       - credential: Transient API key. Public endpoints ignore it and send no authorization header.
     - Returns: Fresh or cached models, or `nil` when neither source is usable.
     - Side effects: May perform one HTTPS GET and atomically write sanitized JSON to the cache
       directory.
     - Failure modes: Unsupported providers, missing required credentials, transport failures,
       non-success HTTP responses, malformed JSON, and empty filtered results retain any existing
       cache and return it when available.
     */
    @discardableResult
    public func refreshIfNeeded(
        provider: LLMProvider,
        endpoint: URL,
        credential: String
    ) async -> [AIAvailableModel]? {
        guard AIModelCatalog.supportsDynamicModels(provider) else {
            return cachedModels(for: provider)
        }

        let cached = cachedModels(for: provider)
        guard needsRefresh(for: provider) else { return cached }

        let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIModelCatalog.modelsEndpointIsPublic(provider) || !trimmedCredential.isEmpty else {
            return cached
        }

        let fetchCredential = AIModelCatalog.modelsEndpointIsPublic(provider) ? "" : trimmedCredential
        return await fetchModels(
            provider: provider,
            endpoint: endpoint,
            credential: fetchCredential
        ) ?? cached
    }

    /**
     Fetches and replaces one provider's cache without applying an age check.

     - Parameters:
       - provider: Provider enum used only for capabilities and cache identity.
       - endpoint: Provider base endpoint.
       - credential: Transient bearer credential. Public endpoints ignore it, and an empty value
         emits no authorization header.
     - Returns: Non-empty filtered chat models after a successful response, otherwise `nil`.
     - Side effects: Performs one cancellable GET request, updates actor memory, and best-effort
       atomically writes public model metadata to disk.
     - Failure modes: Returns `nil` for unsupported providers, URL loading errors, non-2xx status,
       invalid JSON, or a response containing no chat-capable model identifiers. Errors never include
       the credential.
     */
    @discardableResult
    public func fetchModels(
        provider: LLMProvider,
        endpoint: URL,
        credential: String
    ) async -> [AIAvailableModel]? {
        guard AIModelCatalog.supportsDynamicModels(provider) else { return nil }
        let requestCredential = AIModelCatalog.modelsEndpointIsPublic(provider) ? "" : credential

        var request = URLRequest(url: endpoint.appendingPathComponent("models", isDirectory: false))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if !requestCredential.isEmpty {
            request.setValue("Bearer \(requestCredential)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let decodedModels = try Self.decodeModels(from: data)
            let models = Self.removingCredentialEchoes(
                from: decodedModels,
                credential: requestCredential
            )
            guard !models.isEmpty else { return nil }

            let envelope = CacheEnvelope(fetchedAt: now(), models: models)
            memoryCache[provider] = envelope
            try? persist(envelope, for: provider)
            return models
        } catch {
            return nil
        }
    }

    /** Returns a memory or disk cache envelope without contacting a provider. */
    private func cacheEnvelope(for provider: LLMProvider) -> CacheEnvelope? {
        if let cached = memoryCache[provider] {
            return cached
        }
        guard let data = try? Data(contentsOf: cacheFileURL(for: provider)),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              !envelope.models.isEmpty else {
            return nil
        }
        memoryCache[provider] = envelope
        return envelope
    }

    /** Atomically writes one public cache envelope after creating its directory if needed. */
    private func persist(_ envelope: CacheEnvelope, for provider: LLMProvider) throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: cacheFileURL(for: provider), options: .atomic)
    }

    /** Builds a cache path from a fixed enum raw value rather than any credential or endpoint text. */
    private func cacheFileURL(for provider: LLMProvider) -> URL {
        cacheDirectory.appendingPathComponent(
            "models_cache_\(provider.rawValue).json",
            isDirectory: false
        )
    }

    /**
     Decodes an OpenAI-compatible model response and removes Android's non-chat identifiers.

     Endpoint prices are per token and are converted to per-million rates. Missing or non-positive
     pricing remains unknown so the add-model dialog offers editable custom rates.
     */
    private static func decodeModels(from data: Data) throws -> [AIAvailableModel] {
        let response = try JSONDecoder().decode(APIModelsResponse.self, from: data)
        return response.data.compactMap { apiModel in
            let modelID = apiModel.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, !isNonChatModel(modelID) else { return nil }

            let prompt = finitePositivePrice(apiModel.pricing?.prompt)
            let completion = finitePositivePrice(apiModel.pricing?.completion)
            let pricing: AIModelPricing?
            if prompt > 0 || completion > 0 {
                pricing = AIModelPricing(
                    inputPerMillion: prompt * 1_000_000,
                    outputPerMillion: completion * 1_000_000
                )
            } else {
                pricing = nil
            }
            let trimmedName = apiModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIAvailableModel(
                id: modelID,
                name: trimmedName.isEmpty ? modelID : trimmedName,
                pricing: pricing
            )
        }.sorted { $0.id < $1.id }
    }

    /// Parses finite positive endpoint pricing while treating missing and malformed values as zero.
    private static func finitePositivePrice(_ rawValue: String?) -> Double {
        guard let rawValue,
              let value = Double(rawValue),
              value.isFinite,
              value > 0 else {
            return 0
        }
        return value
    }

    /** Excludes exact credential echoes before metadata reaches memory or disk cache state. */
    private static func removingCredentialEchoes(
        from models: [AIAvailableModel],
        credential: String
    ) -> [AIAvailableModel] {
        guard !credential.isEmpty else { return models }
        return models.filter { model in
            !model.id.contains(credential) && !model.name.contains(credential)
        }
    }

    /// Applies Android's case-insensitive exclusion pattern for image, audio, embedding, and tool models.
    private static func isNonChatModel(_ modelID: String) -> Bool {
        modelID.range(
            of: #"audio|realtime|tts|image|transcribe|search|codex|embedding|moderation|whisper|dall-e|sora|babbage|davinci|instruct|robotics|computer-use|\baqa\b|\blive\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Builds the production ephemeral session without URL cache or credential persistence.
    private nonisolated static func productionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Returns the app-scoped cache directory used only for sanitized dynamic model metadata.
    private nonisolated static func productionCacheDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("AIModelCatalog", isDirectory: true)
    }
}

/** Sanitized on-disk cache payload; credentials and endpoint URLs are deliberately absent. */
private struct CacheEnvelope: Codable, Sendable {
    /// Successful fetch time used for Android's seven-day freshness decision.
    let fetchedAt: Date
    /// Public filtered model metadata returned by the endpoint.
    let models: [AIAvailableModel]
}

/** OpenAI-compatible `/models` response with Android's empty-data fallback. */
private struct APIModelsResponse: Decodable {
    /// Provider model objects; missing data decodes as an empty response.
    let data: [APIModel]

    /** Decodes the provider payload while ignoring unknown top-level fields. */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent([APIModel].self, forKey: .data) ?? []
    }

    /// Serialized response keys used by OpenAI-compatible providers.
    private enum CodingKeys: String, CodingKey {
        case data
    }
}

/** One provider model object accepted from a dynamic endpoint. */
private struct APIModel: Decodable {
    /// Exact model identifier.
    let id: String
    /// Optional display name; missing names fall back to `id`.
    let name: String
    /// Optional OpenRouter-style public pricing extension.
    let pricing: APIModelPricing?

    /** Decodes required identity plus optional name and pricing fields. */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        pricing = try container.decodeIfPresent(APIModelPricing.self, forKey: .pricing)
    }

    /// Serialized model keys used by OpenAI-compatible providers.
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case pricing
    }
}

/** OpenRouter-style per-token prompt and completion prices represented as strings. */
private struct APIModelPricing: Decodable {
    /// Prompt price per token, or zero text when omitted.
    let prompt: String
    /// Completion price per token, or zero text when omitted.
    let completion: String

    /** Decodes optional price strings using Android's zero defaults. */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? "0"
        completion = try container.decodeIfPresent(String.self, forKey: .completion) ?? "0"
    }

    /// Serialized pricing keys returned by OpenRouter-compatible endpoints.
    private enum CodingKeys: String, CodingKey {
        case prompt
        case completion
    }
}
