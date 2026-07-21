import Foundation

/**
 OpenAI Chat Completions-compatible request and response adapter.

 This format is shared by Android's Gemini, OpenAI, xAI, Mistral, DeepSeek, Groq, Alibaba,
 OpenRouter, and custom OpenAI-compatible providers.
 */
public struct OpenAICompatibleAdapter: LLMAPIAdapting {
    /** Creates a stateless OpenAI-compatible adapter. */
    public init() {}

    /**
     Builds an authenticated `/chat/completions` request.

     - Parameter request: Resolved provider-neutral request with `.openAI` format.
     - Returns: HTTPS JSON POST request with Bearer authentication.
     - Side effects: none; the credential exists only in the returned request header.
     - Throws: Endpoint, credential, reserved-header, serialization, or message-shape errors.
     */
    public func makeRequest(from request: LLMCompletionRequest) throws -> URLRequest {
        guard request.apiFormat == .openAI else { throw LLMClientError.invalidEndpoint }
        let url = try LLMRequestSecurity.endpoint(
            base: request.endpoint,
            appending: ["chat", "completions"]
        )
        let headers = try LLMRequestSecurity.headers(
            credential: request.credential,
            authentication: ["Authorization": "Bearer \(request.credential)"],
            protocolHeaders: [:],
            extra: request.extraHeaders
        )
        var messages = try request.messages.map(Self.messageJSON)
        let usesCacheBreakpoints = request.supportsCacheControl
            && LLMCacheControl.openAIModelSupportsBreakpoints(request.model)
        if usesCacheBreakpoints {
            LLMCacheControl.markLastMessage(in: &messages, roles: ["user", "tool"])
        }
        var root: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
        ]
        if !request.tools.isEmpty {
            var tools: [JSONValue] = request.tools.map { definition in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(definition.tool.wireName),
                        "description": .string(definition.description),
                        "parameters": .object(definition.parameters),
                    ]),
                ])
            }
            if usesCacheBreakpoints {
                LLMCacheControl.markLastElement(in: &tools)
            }
            root["tools"] = .array(tools)
        }
        if let temperature = request.temperature {
            root["temperature"] = .number(temperature)
        }
        return try LLMRequestSecurity.urlRequest(url: url, headers: headers, body: .object(root))
    }

    /**
     Parses an OpenAI-compatible response, including typed function calls and cached-token usage.

     - Parameter data: Successful HTTP response bytes.
     - Returns: Provider-neutral completion.
     - Side effects: none.
     - Throws: Stable malformed-response, unknown-tool, or malformed-arguments errors without
       embedding provider data in the error.
     */
    public func parseResponse(_ data: Data) throws -> LLMCompletion {
        guard let root = try? JSONValue.decode(data: data).objectValue,
              let choices = root["choices"]?.arrayValue,
              let first = choices.first?.objectValue,
              let message = first["message"]?.objectValue else {
            throw LLMClientError.malformedResponse
        }

        if let rawContent = message["content"],
           rawContent != .null,
           rawContent.stringValue == nil {
            throw LLMClientError.malformedResponse
        }
        if let rawCalls = message["tool_calls"],
           rawCalls != .null,
           rawCalls.arrayValue == nil {
            throw LLMClientError.malformedResponse
        }
        let content = message["content"]?.stringValue?.nilIfBlank
        var calls: [LLMToolCall] = []
        if let rawCalls = message["tool_calls"]?.arrayValue {
            for rawCall in rawCalls {
                guard let call = rawCall.objectValue,
                      call["type"]?.stringValue ?? "function" == "function",
                      let id = call["id"]?.stringValue,
                      !id.isEmpty,
                      let function = call["function"]?.objectValue,
                      let name = function["name"]?.stringValue,
                      let argumentsString = function["arguments"]?.stringValue else {
                    throw LLMClientError.malformedToolArguments
                }
                let arguments: [String: JSONValue]
                if argumentsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    arguments = [:]
                } else {
                    guard let argumentsData = argumentsString.data(using: .utf8),
                          let object = try? JSONValue.decode(data: argumentsData).objectValue else {
                        throw LLMClientError.malformedToolArguments
                    }
                    arguments = object
                }
                guard let tool = AgentTool(wireName: name) else {
                    throw LLMClientError.unknownTool
                }
                let signature = call["extra_content"]?.objectValue?["google"]?
                    .objectValue?["thought_signature"]?.stringValue
                calls.append(
                    LLMToolCall(
                        id: id,
                        tool: tool,
                        arguments: arguments,
                        thoughtSignature: signature
                    )
                )
            }
        }

        let usageObject = root["usage"]?.objectValue
        let promptTokens = usageObject?["prompt_tokens"]?.integerValue ?? 0
        let cachedTokens = usageObject?["prompt_tokens_details"]?
            .objectValue?["cached_tokens"]?.integerValue ?? 0
        let usage = LLMUsage(
            inputTokens: max(promptTokens - cachedTokens, 0),
            outputTokens: usageObject?["completion_tokens"]?.integerValue ?? 0,
            cacheReadTokens: cachedTokens
        )
        return LLMCompletion(content: calls.isEmpty ? (content ?? "") : content, toolCalls: calls, usage: usage)
    }

    /** Converts one provider-neutral message into OpenAI wire JSON. */
    private static func messageJSON(_ message: LLMMessage) throws -> JSONValue {
        switch message.role {
        case .tool:
            guard let toolCallId = message.toolCallId, message.toolCalls.isEmpty else {
                throw LLMClientError.invalidMessage
            }
            return .object([
                "role": .string("tool"),
                "content": .string(message.content ?? ""),
                "tool_call_id": .string(toolCallId),
            ])
        case .assistant where !message.toolCalls.isEmpty:
            guard message.toolCallId == nil else { throw LLMClientError.invalidMessage }
            let calls = try message.toolCalls.map { call -> JSONValue in
                let argumentsData = try JSONValue.object(call.arguments).encodedData()
                guard let arguments = String(data: argumentsData, encoding: .utf8) else {
                    throw LLMClientError.invalidMessage
                }
                var object: [String: JSONValue] = [
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.tool.wireName),
                        "arguments": .string(arguments),
                    ]),
                ]
                if let signature = call.thoughtSignature {
                    object["extra_content"] = .object([
                        "google": .object(["thought_signature": .string(signature)]),
                    ])
                }
                return .object(object)
            }
            return .object([
                "role": .string("assistant"),
                "content": message.content.map(JSONValue.string) ?? .null,
                "tool_calls": .array(calls),
            ])
        default:
            guard message.toolCallId == nil, message.toolCalls.isEmpty else {
                throw LLMClientError.invalidMessage
            }
            return .object([
                "role": .string(message.role.rawValue),
                "content": .string(message.content ?? ""),
            ])
        }
    }
}

/**
 Anthropic Messages request and response adapter with Android-compatible headers and content blocks.
 */
public struct AnthropicMessagesAdapter: LLMAPIAdapting {
    /// Anthropic protocol version pinned by Android.
    public static let protocolVersion = "2023-06-01"

    /// Android's default maximum response tokens for the Messages format.
    public static let defaultMaximumTokens = 8_192

    /** Creates a stateless Anthropic Messages adapter. */
    public init() {}

    /**
     Builds an authenticated `/messages` request.

     System messages become Anthropic system blocks. Consecutive tool results are batched into one
     user message because Anthropic requires all results for a parallel tool-use response together.
     */
    public func makeRequest(from request: LLMCompletionRequest) throws -> URLRequest {
        guard request.apiFormat == .anthropic else { throw LLMClientError.invalidEndpoint }
        let url = try LLMRequestSecurity.endpoint(base: request.endpoint, appending: ["messages"])
        let headers = try LLMRequestSecurity.headers(
            credential: request.credential,
            authentication: ["x-api-key": request.credential],
            protocolHeaders: ["anthropic-version": Self.protocolVersion],
            extra: request.extraHeaders
        )

        let systemMessage = request.messages.last(where: { $0.role == .system })
        let nonSystem = request.messages.filter { $0.role != .system }
        var messages: [JSONValue] = []
        var index = 0
        while index < nonSystem.count {
            if nonSystem[index].role == .tool {
                var blocks: [JSONValue] = []
                while index < nonSystem.count, nonSystem[index].role == .tool {
                    let message = nonSystem[index]
                    guard let callId = message.toolCallId, message.toolCalls.isEmpty else {
                        throw LLMClientError.invalidMessage
                    }
                    blocks.append(.object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(callId),
                        "content": .string(message.content ?? ""),
                    ]))
                    index += 1
                }
                messages.append(.object(["role": .string("user"), "content": .array(blocks)]))
            } else {
                messages.append(try Self.messageJSON(nonSystem[index]))
                index += 1
            }
        }
        LLMCacheControl.markLastMessage(in: &messages, roles: ["user"])

        var root: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "max_tokens": .number(Double(Self.defaultMaximumTokens)),
        ]
        if let systemMessage {
            root["system"] = .array([
                .object([
                    "type": .string("text"),
                    "text": .string(systemMessage.content ?? ""),
                    "cache_control": .object(["type": .string("ephemeral")]),
                ]),
            ])
        }
        if !request.tools.isEmpty {
            var tools = request.tools.map { definition in
                JSONValue.object([
                    "name": .string(definition.tool.wireName),
                    "description": .string(definition.description),
                    "input_schema": .object(definition.parameters),
                ])
            }
            if case .object(var last) = tools[tools.count - 1] {
                last["cache_control"] = LLMCacheControl.breakpoint
                tools[tools.count - 1] = .object(last)
            }
            root["tools"] = .array(tools)
        }
        if let temperature = request.temperature {
            root["temperature"] = .number(temperature)
        }
        return try LLMRequestSecurity.urlRequest(url: url, headers: headers, body: .object(root))
    }

    /** Parses text and typed `tool_use` blocks from an Anthropic Messages response. */
    public func parseResponse(_ data: Data) throws -> LLMCompletion {
        guard let root = try? JSONValue.decode(data: data).objectValue,
              let blocks = root["content"]?.arrayValue else {
            throw LLMClientError.malformedResponse
        }
        var text = ""
        var calls: [LLMToolCall] = []
        for rawBlock in blocks {
            guard let block = rawBlock.objectValue, let type = block["type"]?.stringValue else {
                throw LLMClientError.malformedResponse
            }
            switch type {
            case "text":
                guard let value = block["text"]?.stringValue else {
                    throw LLMClientError.malformedResponse
                }
                text.append(value)
            case "tool_use":
                guard let id = block["id"]?.stringValue,
                      !id.isEmpty,
                      let name = block["name"]?.stringValue,
                      let arguments = block["input"]?.objectValue else {
                    throw LLMClientError.malformedToolArguments
                }
                guard let tool = AgentTool(wireName: name) else {
                    throw LLMClientError.unknownTool
                }
                calls.append(LLMToolCall(id: id, tool: tool, arguments: arguments))
            default:
                throw LLMClientError.malformedResponse
            }
        }
        let usageObject = root["usage"]?.objectValue
        let usage = LLMUsage(
            inputTokens: usageObject?["input_tokens"]?.integerValue ?? 0,
            outputTokens: usageObject?["output_tokens"]?.integerValue ?? 0,
            cacheCreationTokens: usageObject?["cache_creation_input_tokens"]?.integerValue ?? 0,
            cacheReadTokens: usageObject?["cache_read_input_tokens"]?.integerValue ?? 0
        )
        return LLMCompletion(
            content: calls.isEmpty ? (text.nilIfBlank ?? "") : text.nilIfBlank,
            toolCalls: calls,
            usage: usage
        )
    }

    /** Converts a non-system, non-tool-result message into Anthropic wire JSON. */
    private static func messageJSON(_ message: LLMMessage) throws -> JSONValue {
        guard message.role == .user || message.role == .assistant,
              message.toolCallId == nil else {
            throw LLMClientError.invalidMessage
        }
        if message.role == .assistant, !message.toolCalls.isEmpty {
            var blocks: [JSONValue] = []
            if let content = message.content {
                blocks.append(.object(["type": .string("text"), "text": .string(content)]))
            }
            blocks.append(contentsOf: message.toolCalls.map { call in
                .object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.tool.wireName),
                    "input": .object(call.arguments),
                ])
            })
            return .object(["role": .string("assistant"), "content": .array(blocks)])
        }
        guard message.toolCalls.isEmpty else { throw LLMClientError.invalidMessage }
        return .object([
            "role": .string(message.role.rawValue),
            "content": .string(message.content ?? ""),
        ])
    }
}

/** Android-compatible ephemeral cache-breakpoint placement shared by both wire formats. */
private enum LLMCacheControl {
    /// Provider wire value for an ephemeral cache breakpoint.
    static let breakpoint = JSONValue.object(["type": .string("ephemeral")])

    /** Marks the last message whose role is in the supplied set. */
    static func markLastMessage(in messages: inout [JSONValue], roles: Set<String>) {
        guard let index = messages.lastIndex(where: {
            guard case .object(let object) = $0 else { return false }
            return object["role"]?.stringValue.map(roles.contains) == true
        }), case .object(var message) = messages[index], let content = message["content"] else {
            return
        }
        message["content"] = marking(content)
        messages[index] = .object(message)
    }

    /** Marks the last object in a provider tool array. */
    static func markLastElement(in values: inout [JSONValue]) {
        guard !values.isEmpty, case .object(var last) = values[values.count - 1] else {
            return
        }
        last["cache_control"] = breakpoint
        values[values.count - 1] = .object(last)
    }

    /** Adds a breakpoint to primitive text or the final object in a content-block array. */
    private static func marking(_ content: JSONValue) -> JSONValue {
        switch content {
        case .string(let text):
            return .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "cache_control": breakpoint,
                ]),
            ])
        case .array(var blocks):
            guard !blocks.isEmpty, case .object(var last) = blocks[blocks.count - 1] else {
                return content
            }
            last["cache_control"] = breakpoint
            blocks[blocks.count - 1] = .object(last)
            return .array(blocks)
        default:
            return content
        }
    }

    /** Mirrors Android's OpenRouter Claude cache-control model gate. */
    static func openAIModelSupportsBreakpoints(_ model: String) -> Bool {
        guard model.hasPrefix("anthropic/claude") else { return false }
        let unsupportedPrefixes = [
            "anthropic/claude-3-haiku",
            "anthropic/claude-3.5-haiku",
            "anthropic/claude-3-5-haiku",
            "anthropic/claude-3.5-sonnet",
            "anthropic/claude-3-5-sonnet",
            "anthropic/claude-3.7-sonnet",
            "anthropic/claude-3-7-sonnet",
        ]
        return !unsupportedPrefixes.contains(where: model.hasPrefix)
    }
}

/** Security and serialization rules shared by both provider adapters. */
private enum LLMRequestSecurity {
    /** Validates an HTTPS base endpoint and appends provider route components. */
    static func endpoint(base: URL, appending components: [String]) throws -> URL {
        guard base.scheme?.lowercased() == "https", base.host != nil else {
            throw base.scheme?.lowercased() == "https"
                ? LLMClientError.invalidEndpoint
                : LLMClientError.insecureEndpoint
        }
        guard base.user == nil, base.password == nil else {
            throw LLMClientError.endpointContainsCredentials
        }
        guard base.query == nil, base.fragment == nil else {
            throw LLMClientError.invalidEndpoint
        }
        return components.reduce(base) { result, component in
            result.appendingPathComponent(component)
        }
    }

    /** Merges headers while preventing authentication or protocol replacement. */
    static func headers(
        credential: String,
        authentication: [String: String],
        protocolHeaders: [String: String],
        extra: [String: String]
    ) throws -> [String: String] {
        guard !credential.isEmpty,
              validHeaderValue(credential) else {
            throw LLMClientError.missingCredential
        }
        let reserved = Set(
            (Array(authentication.keys) + Array(protocolHeaders.keys) + ["Content-Type"])
                .map { $0.lowercased() }
        )
        for (key, value) in extra {
            guard validHeaderName(key), validHeaderValue(value) else {
                throw LLMClientError.invalidHeader
            }
            if reserved.contains(key.lowercased()) {
                throw LLMClientError.reservedHeader
            }
        }
        return authentication
            .merging(protocolHeaders) { current, _ in current }
            .merging(["Content-Type": "application/json"]) { current, _ in current }
            .merging(extra) { current, _ in current }
    }

    /** Accepts only RFC 9110 token characters in an extra header field name. */
    private static func validHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            case 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                return true
            default:
                return false
            }
        }
    }

    /** Rejects line breaks and HTTP control bytes while permitting horizontal tabs. */
    private static func validHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9
                || (!CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.newlines.contains(scalar))
        }
    }

    /** Builds a POST request from validated scalar values. */
    static func urlRequest(
        url: URL,
        headers: [String: String],
        body: JSONValue
    ) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        do {
            request.httpBody = try body.encodedData()
        } catch {
            throw LLMClientError.invalidRequest
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}

/** Internal string normalization used only for optional provider text. */
private extension String {
    /// Returns `nil` for blank text while preserving nonblank provider whitespace verbatim.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
