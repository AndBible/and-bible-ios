import Foundation
import XCTest
@testable import BibleCore

/**
 Protects provider-specific request/response contracts and URLSession transport safety.

 All HTTP behavior uses injected URLProtocol sessions. The suite never reaches DNS or provider
 endpoints and resets static protocol hooks after each asynchronous test.
 */
final class LLMTransportBehaviorTests: XCTestCase {
    /**
     Verifies OpenAI-compatible headers, body shape, typed tool parsing, and cached-token accounting.

     Failure means a supported OpenAI-style provider would receive an incompatible request or tool
     iterations would lose typed routing and usage accounting.
     */
    func testOpenAIAdapterBuildsAndParsesAndroidCompatiblePayloads() throws {
        let adapter = OpenAICompatibleAdapter()
        let definition = LLMToolDefinition(
            tool: .searchBible,
            description: "Search",
            parameters: ["type": .string("object")]
        )
        let request = try adapter.makeRequest(
            from: LLMCompletionRequest(
                endpoint: URL(string: "https://api.example.test/v1")!,
                credential: "secret-key",
                apiFormat: .openAI,
                model: "model-a",
                messages: [LLMMessage(role: .system, content: "system"), LLMMessage(role: .user, content: "question")],
                tools: [definition],
                temperature: 0.3,
                extraHeaders: ["x-grok-conv-id": "conversation"]
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-grok-conv-id"), "conversation")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(request.httpBody).jsonObject
        XCTAssertEqual(body["model"] as? String, "model-a")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "searchBible")

        let response = Data(#"{"choices":[{"message":{"content":"Working","tool_calls":[{"id":"call-1","type":"function","function":{"name":"searchBible","arguments":"{\"query\":\"grace\"}"}}]}}],"usage":{"prompt_tokens":20,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":7}}}"#.utf8)
        let parsed = try adapter.parseResponse(response)
        XCTAssertEqual(parsed.content, "Working")
        XCTAssertEqual(parsed.toolCalls.first?.tool, .searchBible)
        XCTAssertEqual(parsed.toolCalls.first?.arguments["query"], .string("grace"))
        XCTAssertEqual(parsed.usage, LLMUsage(inputTokens: 13, outputTokens: 5, cacheReadTokens: 7))
    }

    /**
     Verifies Anthropic system blocks, protocol headers, tool schema, response blocks, and four-way
     usage counters.

     Failure means Anthropic Messages requests would be rejected or lose cache accounting.
     */
    func testAnthropicAdapterBuildsAndParsesMessagesPayloads() throws {
        let adapter = AnthropicMessagesAdapter()
        let request = try adapter.makeRequest(
            from: LLMCompletionRequest(
                endpoint: URL(string: "https://api.anthropic.com/v1")!,
                credential: "anthropic-key",
                apiFormat: .anthropic,
                model: "claude-test",
                messages: [
                    LLMMessage(role: .system, content: "old-system"),
                    LLMMessage(role: .user, content: "question"),
                    LLMMessage(role: .system, content: "system"),
                ],
                tools: [LLMToolDefinition(tool: .getVerseContent, description: "Read", parameters: ["type": .string("object")])]
            )
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            AnthropicMessagesAdapter.protocolVersion
        )
        let body = try XCTUnwrap(request.httpBody).jsonObject
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicMessagesAdapter.defaultMaximumTokens)
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "system")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let lastContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(
            (lastContent.last?["cache_control"] as? [String: Any])?["type"] as? String,
            "ephemeral"
        )

        let response = Data(#"{"content":[{"type":"text","text":"Reading"},{"type":"tool_use","id":"tool-1","name":"getVerseContent","input":{"book":"KJV"}}],"usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}"#.utf8)
        let parsed = try adapter.parseResponse(response)
        XCTAssertEqual(parsed.content, "Reading")
        XCTAssertEqual(parsed.toolCalls.first?.tool, .getVerseContent)
        XCTAssertEqual(parsed.toolCalls.first?.arguments["book"], .string("KJV"))
        XCTAssertEqual(
            parsed.usage,
            LLMUsage(inputTokens: 10, outputTokens: 4, cacheCreationTokens: 3, cacheReadTokens: 2)
        )
    }

    /**
     Verifies endpoint validation rejects non-HTTPS URLs and URL user-info before a request exists.

     Failure would permit credential disclosure through cleartext transport or endpoint URLs.
     */
    func testAdaptersRejectInsecureEndpointsAndURLCredentials() {
        let adapter = OpenAICompatibleAdapter()
        XCTAssertThrowsError(
            try adapter.makeRequest(
                from: completionRequest(endpoint: URL(string: "http://api.example.test/v1")!)
            )
        ) { XCTAssertEqual($0 as? LLMClientError, .insecureEndpoint) }
        XCTAssertThrowsError(
            try adapter.makeRequest(
                from: completionRequest(endpoint: URL(string: "https://user:pass@api.example.test/v1")!)
            )
        ) { XCTAssertEqual($0 as? LLMClientError, .endpointContainsCredentials) }
    }

    /**
     Verifies OpenRouter-compatible Claude requests receive Android's message and tool cache
     breakpoints while ordinary OpenAI requests remain unchanged.

     Failure would increase token cost or send unsupported cache fields to providers.
     */
    func testOpenAIAdapterGatesCacheBreakpointsByProviderCapabilityAndModel() throws {
        let adapter = OpenAICompatibleAdapter()
        let definition = LLMToolDefinition(
            tool: .searchBible,
            description: "Search",
            parameters: ["type": .string("object"), "properties": .object([:])]
        )
        let cachedRequest = try adapter.makeRequest(
            from: LLMCompletionRequest(
                endpoint: URL(string: "https://openrouter.ai/api/v1")!,
                credential: "secret",
                apiFormat: .openAI,
                model: "anthropic/claude-sonnet-4",
                messages: [LLMMessage(role: .user, content: "question")],
                tools: [definition],
                supportsCacheControl: true
            )
        )
        let cachedBody = try XCTUnwrap(cachedRequest.httpBody).jsonObject
        let cachedMessages = try XCTUnwrap(cachedBody["messages"] as? [[String: Any]])
        let cachedContent = try XCTUnwrap(cachedMessages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(
            (cachedContent.last?["cache_control"] as? [String: Any])?["type"] as? String,
            "ephemeral"
        )
        let cachedTools = try XCTUnwrap(cachedBody["tools"] as? [[String: Any]])
        XCTAssertEqual(
            (cachedTools.last?["cache_control"] as? [String: Any])?["type"] as? String,
            "ephemeral"
        )

        let uncachedRequest = try adapter.makeRequest(
            from: LLMCompletionRequest(
                endpoint: URL(string: "https://api.openai.com/v1")!,
                credential: "secret",
                apiFormat: .openAI,
                model: "gpt-test",
                messages: [LLMMessage(role: .user, content: "question")],
                tools: [definition]
            )
        )
        let uncachedBody = try XCTUnwrap(uncachedRequest.httpBody).jsonObject
        let uncachedMessages = try XCTUnwrap(uncachedBody["messages"] as? [[String: Any]])
        XCTAssertEqual(uncachedMessages.last?["content"] as? String, "question")
    }

    /**
     Verifies header injection is rejected and common request diagnostics never reflect credentials.

     Failure could permit request smuggling or leak API keys through routine error logging.
     */
    func testAdapterRejectsHeaderInjectionAndRequestDiagnosticsRedactCredential() {
        let request = LLMCompletionRequest(
            endpoint: URL(string: "https://api.example.test/v1")!,
            credential: "private-credential",
            apiFormat: .openAI,
            model: "model",
            messages: [LLMMessage(role: .user, content: "hello")],
            extraHeaders: ["X-Trace": "safe\r\nAuthorization: exposed"]
        )

        XCTAssertThrowsError(try OpenAICompatibleAdapter().makeRequest(from: request)) {
            XCTAssertEqual($0 as? LLMClientError, .invalidHeader)
        }
        let unicodeInjection = LLMCompletionRequest(
            endpoint: URL(string: "https://api.example.test/v1")!,
            credential: "private-credential",
            apiFormat: .openAI,
            model: "model",
            messages: [LLMMessage(role: .user, content: "hello")],
            extraHeaders: ["X-Trace": "safe\u{2028}Authorization: exposed"]
        )
        XCTAssertThrowsError(try OpenAICompatibleAdapter().makeRequest(from: unicodeInjection)) {
            XCTAssertEqual($0 as? LLMClientError, .invalidHeader)
        }
        XCTAssertFalse(String(describing: request).contains("private-credential"))
        XCTAssertFalse(String(reflecting: request).contains("private-credential"))

        let nonEncodable = LLMCompletionRequest(
            endpoint: URL(string: "https://api.example.test/v1")!,
            credential: "private-credential",
            apiFormat: .openAI,
            model: "model",
            messages: [LLMMessage(role: .user, content: "hello")],
            temperature: .nan
        )
        XCTAssertThrowsError(try OpenAICompatibleAdapter().makeRequest(from: nonEncodable)) {
            XCTAssertEqual($0 as? LLMClientError, .invalidRequest)
            XCTAssertFalse(String(describing: $0).contains("private-credential"))
        }
    }

    /**
     Verifies an authenticated redirect cannot change host and an HTTPS same-origin redirect remains
     eligible.

     Failure means URLSession could forward Bearer or Anthropic keys to an attacker-controlled host.
     */
    func testAuthenticatedRedirectPolicyRejectsCrossOriginTargets() {
        var original = URLRequest(url: URL(string: "https://api.example.test/v1/chat/completions")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let crossOrigin = URLRequest(url: URL(string: "https://other.example.test/v1/chat/completions")!)
        let sameOrigin = URLRequest(url: URL(string: "https://api.example.test/v2/chat/completions")!)

        XCTAssertEqual(
            LLMRedirectPolicy.rejection(originalRequest: original, redirectRequest: crossOrigin),
            .authenticatedCrossOriginRedirect
        )
        XCTAssertNil(
            LLMRedirectPolicy.rejection(originalRequest: original, redirectRequest: sameOrigin)
        )
    }

    /**
     Verifies unknown tools and malformed top-level responses fail explicitly without raw response
     content entering the error.

     Failure means a model could silently invoke unsupported behavior or provider data could leak.
     */
    func testMalformedResponsesAndUnknownToolsReturnStableErrors() {
        let adapter = OpenAICompatibleAdapter()
        XCTAssertThrowsError(try adapter.parseResponse(Data(#"{"choices":[]}"#.utf8))) {
            XCTAssertEqual($0 as? LLMClientError, .malformedResponse)
        }
        let invalidContent = Data(#"{"choices":[{"message":{"content":{"private":"text"}}}]}"#.utf8)
        XCTAssertThrowsError(try adapter.parseResponse(invalidContent)) {
            XCTAssertEqual($0 as? LLMClientError, .malformedResponse)
            XCTAssertFalse(String(describing: $0).contains("private"))
        }
        let unknown = Data(#"{"choices":[{"message":{"tool_calls":[{"id":"1","type":"function","function":{"name":"eraseEverything","arguments":"{}"}}]}}]}"#.utf8)
        XCTAssertThrowsError(try adapter.parseResponse(unknown)) {
            XCTAssertEqual($0 as? LLMClientError, .unknownTool)
            XCTAssertFalse(String(describing: $0).contains("arguments"))
        }
        let blankArguments = Data(#"{"choices":[{"message":{"tool_calls":[{"id":"1","type":"function","function":{"name":"searchBible","arguments":""}}]}}]}"#.utf8)
        XCTAssertEqual(
            try? adapter.parseResponse(blankArguments).toolCalls.first?.arguments,
            [:]
        )
        let unknownAnthropicBlock = Data(#"{"content":[{"type":"thinking","thinking":"private"}]}"#.utf8)
        XCTAssertThrowsError(
            try AnthropicMessagesAdapter().parseResponse(unknownAnthropicBlock)
        ) {
            XCTAssertEqual($0 as? LLMClientError, .malformedResponse)
        }
    }

    /**
     Verifies task cancellation stops the underlying injected URLProtocol load and surfaces
     `CancellationError` instead of a generic or secret-bearing transport failure.

     Synchronization uses expectations fired by `startLoading` and `stopLoading`; no timing sleep or
     external network is involved.
     */
    func testHTTPClientCancellationStopsInjectedURLProtocolLoad() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request stopped")
        HangingURLProtocol.onStart = { started.fulfill() }
        HangingURLProtocol.onStop = { stopped.fulfill() }
        defer { HangingURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let client = LLMHTTPClient(session: URLSession(configuration: configuration))
        let task = Task { try await client.complete(completionRequest(endpoint: URL(string: "https://api.example.test/v1")!)) }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected stable cancellation path.
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    /** Builds a minimal valid OpenAI-compatible request for endpoint and transport tests. */
    private func completionRequest(endpoint: URL) -> LLMCompletionRequest {
        LLMCompletionRequest(
            endpoint: endpoint,
            credential: "secret",
            apiFormat: .openAI,
            model: "model",
            messages: [LLMMessage(role: .user, content: "hello")]
        )
    }
}

/** Test-only JSON object projection for assertions on encoded request bodies. */
private extension Data {
    /// Parses a JSON object, failing the calling test through its thrown error when malformed.
    var jsonObject: [String: Any] {
        get throws {
            try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
        }
    }
}

/**
 URLProtocol double that starts a request and waits indefinitely until URLSession cancellation.

 Static callbacks are reset by the test. The double emits no response bytes, so completion can only
 happen through task cancellation and `stopLoading`.
 */
private final class HangingURLProtocol: URLProtocol {
    /// Called synchronously when URLSession begins loading.
    static var onStart: (() -> Void)?
    /// Called synchronously when URLSession cancels the protocol load.
    static var onStop: (() -> Void)?

    /** Accepts every request in the injected ephemeral session. */
    override class func canInit(with request: URLRequest) -> Bool { true }

    /** Returns the request unchanged because no canonicalization is required. */
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /** Signals that the synthetic indefinite load began. */
    override func startLoading() {
        Self.onStart?()
    }

    /** Signals that cancellation propagated to URL loading. */
    override func stopLoading() {
        Self.onStop?()
    }

    /** Clears callbacks so no test state leaks to later URLSession work. */
    static func reset() {
        onStart = nil
        onStop = nil
    }
}
