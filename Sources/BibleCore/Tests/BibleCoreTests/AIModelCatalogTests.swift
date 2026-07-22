import Foundation
import XCTest
@testable import BibleCore

/**
 Contract tests for Android's built-in and dynamic model catalogs.

 Tests use only value types, a temporary cache directory, and the package's intercepted URL session.
 No provider network, Keychain, SwiftData, CloudKit, or durable app cache is touched.
 */
final class AIModelCatalogTests: XCTestCase {
    /** Clears the process-global URL interceptor after each dynamic-service test. */
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Pins every model identifier and capability from Android `service/llm/LlmUtils.kt`.

     The representative price, support, stripped-prefix, and capability assertions prove the
     catalog carries behavior rather than only names. A failure means add/edit UI, pricing locks, or
     supported badges can diverge from Android.
     */
    func testBuiltInCatalogMatchesAndroidModelIDsPricingAndCapabilities() throws {
        XCTAssertEqual(
            AIModelCatalog.models(for: .gemini).map(\.id),
            [
                "gemini-3-flash-preview",
                "gemini-3.1-pro-preview",
                "gemini-2.5-pro",
                "gemini-2.5-flash",
            ]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .openAI).map(\.id),
            [
                "gpt-5.4-mini",
                "gpt-5.4",
                "gpt-5-mini",
                "gpt-5-nano",
                "gpt-5.2",
                "gpt-4o-mini",
            ]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .anthropic).map(\.id),
            ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-6"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .xAI).map(\.id),
            ["grok-4-0709", "grok-4-1-fast-reasoning", "grok-3-mini"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .mistral).map(\.id),
            ["mistral-small-latest", "mistral-large-latest"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .deepSeek).map(\.id),
            ["deepseek-chat", "deepseek-reasoner"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .groq).map(\.id),
            ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "llama-3.1-8b-instant"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .alibaba).map(\.id),
            ["qwen-plus", "qwen-turbo", "qwen3-max"]
        )
        XCTAssertEqual(
            AIModelCatalog.models(for: .openRouter).map(\.id),
            [
                "anthropic/claude-sonnet-4",
                "google/gemini-3-flash",
                "openai/gpt-5.4-mini",
            ]
        )
        XCTAssertTrue(AIModelCatalog.models(for: .custom).isEmpty)

        let pricing = try XCTUnwrap(AIModelCatalog.pricing(for: "gemini-2.5-pro"))
        XCTAssertEqual(pricing.inputPerMillion, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(pricing.outputPerMillion, 10.00, accuracy: 0.000_001)
        XCTAssertEqual(pricing.cacheReadPerMillion, 0.3125, accuracy: 0.000_001)
        XCTAssertTrue(AIModelCatalog.isSupported("gemini-2.5-pro"))
        XCTAssertTrue(AIModelCatalog.isSupported("openai/gpt-5.4-mini"))
        XCTAssertFalse(AIModelCatalog.isSupported("openai/gpt-oss-120b"))
        XCTAssertFalse(AIModelCatalog.supportsDynamicModels(.anthropic))
        XCTAssertFalse(AIModelCatalog.supportsDynamicModels(.custom))
        XCTAssertTrue(AIModelCatalog.supportsDynamicModels(.openAI))
        XCTAssertTrue(AIModelCatalog.modelsEndpointIsPublic(.openRouter))
        XCTAssertFalse(AIModelCatalog.modelsEndpointIsPublic(.gemini))
    }

    /**
     Protects Android's category, supported-only default, custom-provider fallback, and price order.

     The mixed fixture includes slash categories, supported and unsupported models, equal capability
     sources, and dynamic pricing. A failure means the add-model dialog can hide every community
     choice, show unsupported entries too early, or order expensive choices before cheaper ones.
     */
    func testSelectionPolicyUsesDynamicCacheCategoriesSupportFilterAndPriceOrder() {
        let dynamicModels = [
            AIAvailableModel(
                id: "vendor/unpriced",
                name: "Unpriced",
                pricing: nil
            ),
            AIAvailableModel(
                id: "openai/gpt-oss-120b",
                name: "OSS",
                pricing: AIModelPricing(inputPerMillion: 0.30, outputPerMillion: 0.60)
            ),
            AIAvailableModel(
                id: "openai/gpt-5.4-mini",
                name: "Mini",
                pricing: AIModelPricing(inputPerMillion: 0.75, outputPerMillion: 4.50)
            ),
            AIAvailableModel(
                id: "anthropic/claude-sonnet-4-6",
                name: "Sonnet",
                pricing: AIModelPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
            ),
        ]

        XCTAssertEqual(
            AIModelCatalog.availableModels(for: .openAI, cachedModels: dynamicModels),
            dynamicModels
        )
        XCTAssertEqual(
            AIModelCatalog.categories(in: dynamicModels),
            ["anthropic", "openai", "vendor"]
        )
        XCTAssertEqual(
            AIModelCatalog.categories(
                in: dynamicModels + [
                    AIAvailableModel(id: "OpenAI/second", name: "Second", pricing: nil),
                ]
            ),
            ["OpenAI", "anthropic", "openai", "vendor"]
        )
        XCTAssertFalse(AIModelCatalog.initiallyIncludesUnsupported(in: dynamicModels))
        XCTAssertTrue(AIModelCatalog.showsUnsupportedToggle(in: dynamicModels))
        XCTAssertEqual(
            AIModelCatalog.selectableModels(
                from: dynamicModels,
                category: "OPENAI",
                includesUnsupported: false
            ).map(\.id),
            ["openai/gpt-5.4-mini"]
        )
        XCTAssertEqual(
            AIModelCatalog.selectableModels(
                from: dynamicModels,
                category: nil,
                includesUnsupported: true
            ).map(\.id),
            [
                "openai/gpt-oss-120b",
                "openai/gpt-5.4-mini",
                "anthropic/claude-sonnet-4-6",
                "vendor/unpriced",
            ]
        )

        let communityOnly = AIModelCatalog.models(for: .mistral)
        XCTAssertTrue(AIModelCatalog.initiallyIncludesUnsupported(in: communityOnly))
        XCTAssertFalse(AIModelCatalog.showsUnsupportedToggle(in: communityOnly))
        XCTAssertEqual(
            AIModelCatalog.availableModels(for: .custom, cachedModels: dynamicModels),
            []
        )
    }

    /**
     Verifies authenticated fetch, chat filtering, price conversion, seven-day reuse, and cache safety.

     The intercepted request receives a transient bearer key and returns one model whose display
     name echoes it. That entry must be rejected, and the resulting JSON cache must not contain the
     key or an authorization field. A second refresh at the same time must use the cache without
     another request. A failure indicates credential persistence, incorrect endpoint parsing,
     model-type leakage, or broken freshness behavior.
     */
    func testDynamicFetchCachesOnlySanitizedChatMetadataAndReusesFreshEntry() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-model-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let requests = RequestLog()
        let credential = "private-model-list-key"
        MockURLProtocol.requestHandler = { request in
            requests.append(method: request.httpMethod ?? "", path: request.url?.path ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential)")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(
                #"{"data":[{"id":"chat-model","name":"Chat","pricing":{"prompt":"0.000003","completion":"0.000015"}},{"id":"credential-echo","name":"private-model-list-key"},{"id":"gpt-image-1"},{"id":"deliver-live-preview"},{"id":"openai/gpt-5.4-mini","name":""},{"id":"   "}],"ignored":true}"#.utf8
            )
            return (response, body)
        }
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let service = AIDynamicModelService(
            session: makeMockedURLSession(),
            cacheDirectory: cacheDirectory,
            now: { fixedDate }
        )

        let fetched = await service.refreshIfNeeded(
            provider: .openAI,
            endpoint: URL(string: "https://example.test/v1")!,
            credential: credential
        )
        let first = try XCTUnwrap(fetched)
        XCTAssertEqual(first.map(\.id), ["chat-model", "openai/gpt-5.4-mini"])
        let dynamicPricing = try XCTUnwrap(first.first?.pricing)
        XCTAssertEqual(dynamicPricing.inputPerMillion, 3.00, accuracy: 0.000_001)
        XCTAssertEqual(dynamicPricing.outputPerMillion, 15.00, accuracy: 0.000_001)
        XCTAssertEqual(dynamicPricing.cacheCreationPerMillion, 3.00, accuracy: 0.000_001)
        XCTAssertEqual(dynamicPricing.cacheReadPerMillion, 0.30, accuracy: 0.000_001)

        let second = await service.refreshIfNeeded(
            provider: .openAI,
            endpoint: URL(string: "https://example.test/v1")!,
            credential: credential
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(requests.snapshot(), [RequestLogEntry(method: "GET", path: "/v1/models")])

        let cacheURL = cacheDirectory.appendingPathComponent("models_cache_OPENAI.json")
        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(cacheText.contains(credential))
        XCTAssertFalse(cacheText.localizedCaseInsensitiveContains("authorization"))

        let reloadedService = AIDynamicModelService(
            session: makeMockedURLSession(),
            cacheDirectory: cacheDirectory,
            now: { fixedDate }
        )
        let reloaded = await reloadedService.cachedModels(for: .openAI)
        XCTAssertEqual(reloaded, first)
        let globalCachedModels = await reloadedService.cachedModelsAcrossProviders()
        XCTAssertEqual(globalCachedModels, first)
        let needsFreshRefresh = await reloadedService.needsRefresh(for: .openAI)
        XCTAssertFalse(needsFreshRefresh)

        let staleService = AIDynamicModelService(
            session: makeMockedURLSession(),
            cacheDirectory: cacheDirectory,
            now: { fixedDate.addingTimeInterval(AIDynamicModelService.androidCacheMaximumAge + 1) }
        )
        let needsStaleRefresh = await staleService.needsRefresh(for: .openAI)
        XCTAssertTrue(needsStaleRefresh)
    }

    /**
     Verifies Android's public OpenRouter model endpoint never receives the saved API credential.

     The request interceptor requires an absent Authorization header while returning valid pricing.
     The sanitized cache is inspected directly afterward. Failure means a public discovery request
     can expose or persist a credential that Android deliberately omits.
     */
    func testPublicDynamicEndpointOmitsAuthorizationAndCachesSanitizedMetadata() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-public-model-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let credential = "openrouter-private-key"
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(
                    #"{"data":[{"id":"vendor/chat","name":"Chat","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#.utf8
                )
            )
        }
        let service = AIDynamicModelService(
            session: makeMockedURLSession(),
            cacheDirectory: cacheDirectory
        )

        let models = await service.refreshIfNeeded(
            provider: .openRouter,
            endpoint: URL(string: "https://openrouter.example/v1")!,
            credential: credential
        )

        XCTAssertEqual(models?.map(\.id), ["vendor/chat"])
        let cacheText = try String(
            contentsOf: cacheDirectory.appendingPathComponent("models_cache_OPENROUTER.json"),
            encoding: .utf8
        )
        XCTAssertFalse(cacheText.contains(credential))
        XCTAssertFalse(cacheText.localizedCaseInsensitiveContains("authorization"))
    }
}
