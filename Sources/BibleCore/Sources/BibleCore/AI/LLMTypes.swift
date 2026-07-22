import Foundation

/**
 Codable, Sendable JSON value used for provider-neutral tool schemas and arguments.
 */
public enum JSONValue: Codable, Equatable, Sendable {
    /// JSON object.
    case object([String: JSONValue])
    /// JSON array.
    case array([JSONValue])
    /// JSON string.
    case string(String)
    /// JSON number.
    case number(Double)
    /// JSON boolean.
    case bool(Bool)
    /// JSON null.
    case null

    /** Decodes one JSON value without accepting non-JSON Foundation types. */
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /** Encodes the represented JSON primitive or container. */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /**
     Parses one complete JSON document.

     - Parameter data: UTF-8 JSON bytes.
     - Returns: Provider-neutral JSON value.
     - Side effects: none.
     - Throws: `DecodingError` for malformed or trailing JSON.
     */
    public static func decode(data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /** Encodes this value as compact JSON bytes. */
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Object payload, or `nil` for non-object values.
    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// Array payload, or `nil` for non-array values.
    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// String payload, or `nil` for non-string values.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Integer payload when the JSON number is finite and integral.
    public var integerValue: Int64? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded(.towardZero) == value else { return nil }
        return Int64(exactly: value)
    }
}

/** Provider-neutral conversation role. */
public enum LLMRole: String, Codable, Sendable {
    /// System instructions.
    case system
    /// User input or Anthropic tool results.
    case user
    /// Assistant text and tool requests.
    case assistant
    /// OpenAI-compatible tool result.
    case tool
}

/** One typed tool invocation returned by a provider. */
public struct LLMToolCall: Equatable, Sendable {
    /// Provider-generated call identity.
    public let id: String
    /// Complete typed Android tool identity.
    public let tool: AgentTool
    /// Parsed JSON object arguments.
    public let arguments: [String: JSONValue]
    /// Gemini/OpenRouter thought signature that must be echoed on the next request.
    public let thoughtSignature: String?

    /** Creates one validated provider-neutral tool call. */
    public init(
        id: String,
        tool: AgentTool,
        arguments: [String: JSONValue],
        thoughtSignature: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
    }
}

/** One provider-neutral chat message. */
public struct LLMMessage: Equatable, Sendable {
    /// Conversation role.
    public let role: LLMRole
    /// Optional text body.
    public let content: String?
    /// Assistant tool calls to replay in conversation history.
    public let toolCalls: [LLMToolCall]
    /// Provider call identity for a tool-result message.
    public let toolCallId: String?

    /**
     Creates a provider-neutral message.

     Tool results use role `.tool` with `toolCallId`; assistant tool history uses role `.assistant`
     and `toolCalls`. Adapters reject incoherent shapes before network I/O.
     */
    public init(
        role: LLMRole,
        content: String? = nil,
        toolCalls: [LLMToolCall] = [],
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

/** Provider-neutral function definition sent to an LLM. */
public struct LLMToolDefinition: Equatable, Sendable {
    /// Complete typed Android tool identity.
    public let tool: AgentTool
    /// Description used by the model to select the function.
    public let description: String
    /// JSON Schema object for function arguments.
    public let parameters: [String: JSONValue]

    /** Creates one typed function definition. */
    public init(tool: AgentTool, description: String, parameters: [String: JSONValue]) {
        self.tool = tool
        self.description = description
        self.parameters = parameters
    }
}

/** Provider-neutral token accounting. */
public struct LLMUsage: Equatable, Sendable {
    /// Non-cached input tokens.
    public let inputTokens: Int64
    /// Output tokens.
    public let outputTokens: Int64
    /// Cache-creation input tokens.
    public let cacheCreationTokens: Int64
    /// Cache-read input tokens.
    public let cacheReadTokens: Int64

    /** Creates non-negative provider-neutral token counters. */
    public init(
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0
    ) {
        self.inputTokens = max(inputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.cacheCreationTokens = max(cacheCreationTokens, 0)
        self.cacheReadTokens = max(cacheReadTokens, 0)
    }

    /// Total tokens represented by every provider usage category.
    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

/** Parsed assistant output from one provider call. */
public struct LLMCompletion: Equatable, Sendable {
    /// Optional assistant text accompanying or replacing tool calls.
    public let content: String?
    /// Typed tool calls requested by the assistant.
    public let toolCalls: [LLMToolCall]
    /// Provider usage counters.
    public let usage: LLMUsage

    /** Creates one parsed completion. */
    public init(content: String?, toolCalls: [LLMToolCall] = [], usage: LLMUsage = LLMUsage()) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

/** Complete provider-neutral request consumed by an injected LLM client. */
public struct LLMCompletionRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Provider base endpoint.
    public let endpoint: URL
    /// Device-only credential copied into request headers only.
    public let credential: String
    /// Provider wire format.
    public let apiFormat: APIFormat
    /// Model identifier sent verbatim.
    public let model: String
    /// Conversation history.
    public let messages: [LLMMessage]
    /// Typed function definitions.
    public let tools: [LLMToolDefinition]
    /// Optional provider sampling temperature.
    public let temperature: Double?
    /// Provider-specific non-authentication headers.
    public let extraHeaders: [String: String]
    /// Whether this OpenAI-compatible provider can forward explicit cache breakpoints.
    public let supportsCacheControl: Bool

    /** Creates an immutable completion request. */
    public init(
        endpoint: URL,
        credential: String,
        apiFormat: APIFormat,
        model: String,
        messages: [LLMMessage],
        tools: [LLMToolDefinition] = [],
        temperature: Double? = nil,
        extraHeaders: [String: String] = [:],
        supportsCacheControl: Bool = false
    ) {
        self.endpoint = endpoint
        self.credential = credential
        self.apiFormat = apiFormat
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.extraHeaders = extraHeaders
        self.supportsCacheControl = supportsCacheControl
    }

    /// Secret-free summary suitable for diagnostics.
    public var description: String {
        "LLMCompletionRequest(apiFormat: \(apiFormat.rawValue), credential: <redacted>)"
    }

    /// Mirrors the secret-free diagnostic summary and never reflects stored fields.
    public var debugDescription: String { description }
}

/** Async completion boundary used by the agent coordinator and URLSession implementation. */
public protocol LLMCompleting: Sendable {
    /**
     Performs one cancellable provider call.

     - Parameter request: Fully resolved request including a transient device-only credential.
     - Returns: Parsed provider-neutral completion.
     - Side effects: Performs network I/O in production implementations.
     - Throws: Cancellation, transport, endpoint-validation, HTTP, or response-shape errors.
     */
    func complete(_ request: LLMCompletionRequest) async throws -> LLMCompletion
}

/** Credential-free transport event retained in Android-compatible raw run transcripts. */
public enum LLMTransportTranscriptEvent: Equatable, Sendable {
    /// Successful HTTP response body captured before provider parsing.
    case responseBody(String)
    /// Stable request or transport failure that excludes headers, credentials, URLs, and bodies.
    case failure(String)
}

/** Run-scoped callback used by transports that can expose raw diagnostic events safely. */
public struct LLMTransportTranscriptReporter: Sendable {
    /// Isolated callback retained only for one provider invocation.
    private let handler: @Sendable (LLMTransportTranscriptEvent) async -> Void

    /** Creates a reporter over one credential-free async callback. */
    public init(
        handler: @escaping @Sendable (LLMTransportTranscriptEvent) async -> Void
    ) {
        self.handler = handler
    }

    /** Forwards one ordered event to the run recorder. */
    public func report(_ event: LLMTransportTranscriptEvent) async {
        await handler(event)
    }
}

/** Optional transport capability for recording raw responses before provider parsing. */
public protocol LLMTransportTranscriptCompleting: LLMCompleting {
    /** Performs one provider call while reporting credential-free transport events in order. */
    func complete(
        _ request: LLMCompletionRequest,
        transcriptReporter: LLMTransportTranscriptReporter
    ) async throws -> LLMCompletion
}

/** Request-building and response-parsing contract for one provider wire format. */
public protocol LLMAPIAdapting: Sendable {
    /** Builds a validated authenticated HTTP request without performing network I/O. */
    func makeRequest(from request: LLMCompletionRequest) throws -> URLRequest

    /** Parses a successful HTTP response without retaining raw provider data. */
    func parseResponse(_ data: Data) throws -> LLMCompletion
}

/**
 Stable, secret-free failures emitted by adapters and the HTTP client.

 Cases intentionally avoid carrying response bodies, credentials, full URLs, or underlying error
 text because those values may contain provider secrets or user-selected content.
 */
public enum LLMClientError: Error, Equatable, Sendable {
    /// Endpoint is absent or cannot form the provider route.
    case invalidEndpoint
    /// Endpoint or redirect is not HTTPS.
    case insecureEndpoint
    /// Endpoint contains URL user-info credentials.
    case endpointContainsCredentials
    /// API key is empty.
    case missingCredential
    /// Extra headers attempt to replace an authentication or protocol header.
    case reservedHeader
    /// An extra header contains an invalid name or line break.
    case invalidHeader
    /// Request values cannot be represented as provider JSON.
    case invalidRequest
    /// Request messages contain a role/field combination the adapter cannot represent.
    case invalidMessage
    /// Provider returned a non-success status. No body text is exposed.
    case httpStatus(Int)
    /// An authenticated redirect crossed origin boundaries.
    case authenticatedCrossOriginRedirect
    /// Provider response is not valid for the selected API format.
    case malformedResponse
    /// Provider requested a tool outside the complete Android enum; its raw name is withheld.
    case unknownTool
    /// Tool arguments are not a JSON object.
    case malformedToolArguments
    /// Network transport failed without exposing underlying secret-bearing text.
    case transportFailure
}
