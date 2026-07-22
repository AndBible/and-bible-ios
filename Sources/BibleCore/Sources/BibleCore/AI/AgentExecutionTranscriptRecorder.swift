// AgentExecutionTranscriptRecorder.swift -- Bounded Android-compatible run transcript capture

import Foundation

/** Ordered diagnostic boundary invoked by the provider and tool execution loop. */
public protocol AgentExecutionRecording: Sendable {
    /** Records the exact regenerated conversation and visible tool definitions once per run. */
    func recordPrepared(
        messages: [LLMMessage],
        toolDefinitions: [LLMToolDefinition]
    ) async

    /** Records one raw successful response or stable transport failure for an iteration. */
    func recordTransportEvent(
        iteration: Int,
        event: LLMTransportTranscriptEvent
    ) async

    /** Records provider usage once per completed iteration. */
    func recordProviderUsage(iteration: Int, usage: LLMUsage) async

    /** Records one typed provider tool request before permission or execution. */
    func recordToolCall(iteration: Int, call: LLMToolCall) async

    /** Records the exact model-visible result envelope for one tool request. */
    func recordToolResult(iteration: Int, callID: String, result: String) async
}

/**
 Collects one credential-free run transcript behind an actor-isolated byte budget.

 The recorder mirrors Android's entry order: tool definitions, initial messages, raw provider
 response, tool calls, and tool results. It never receives request headers, endpoint URLs, or API
 credentials. Capture stops at a conservative pre-formatting ceiling so pretty-printed headings and
 gzip persistence remain below `LLMRunTelemetryService`'s durable one-megabyte limit.
 */
public actor AgentExecutionTranscriptRecorder: AgentExecutionRecording {
    /// Pre-formatting ceiling that leaves room for headings and pretty-printed JSON expansion.
    public static let maximumCapturedByteCount = 384 * 1_024

    /// Ordered entries already accepted under the byte ceiling.
    private var entries: [LLMRunTranscriptEntry] = []
    /// Latest successful usage for each one-based iteration.
    private var usageByIteration: [Int: LLMUsage] = [:]
    /// Conservative UTF-8 bytes attributed to accepted entries.
    private var capturedByteCount = 0
    /// Whether later text entries must be ignored to preserve the hard ceiling.
    private var reachedCaptureLimit = false

    /** Creates an empty recorder without allocating transcript storage eagerly. */
    public init() {}

    /** Records tool definitions before initial messages, matching Android's `RawLlmLog`. */
    public func recordPrepared(
        messages: [LLMMessage],
        toolDefinitions: [LLMToolDefinition]
    ) {
        let definitionBytes = toolDefinitions.reduce(0) { partial, definition in
            partial
                + definition.tool.wireName.utf8.count
                + definition.description.utf8.count
                + Self.encodedByteCount(.object(definition.parameters))
        }
        append(.toolDefinitions(toolDefinitions), estimatedByteCount: definitionBytes)
        for message in messages {
            append(
                .message(role: message.role, content: message.content),
                estimatedByteCount: message.role.rawValue.utf8.count
                    + (message.content?.utf8.count ?? 0)
            )
        }
    }

    /** Records a bounded transport event without provider headers or credentials. */
    public func recordTransportEvent(
        iteration: Int,
        event: LLMTransportTranscriptEvent
    ) {
        let body: String
        switch event {
        case .responseBody(let value), .failure(let value):
            body = value
        }
        append(
            .rawAPIResponse(iteration: iteration, body: body),
            estimatedByteCount: body.utf8.count + 32
        )
    }

    /** Replaces duplicate iteration usage exactly as Android's keyed in-memory map does. */
    public func recordProviderUsage(iteration: Int, usage: LLMUsage) {
        usageByIteration[iteration] = usage
    }

    /** Encodes typed arguments as deterministic compact JSON for the raw tool-call entry. */
    public func recordToolCall(iteration _: Int, call: LLMToolCall) {
        let arguments = Self.encodedString(.object(call.arguments))
        append(
            .toolCall(tool: call.tool, id: call.id, arguments: arguments),
            estimatedByteCount: call.tool.wireName.utf8.count
                + call.id.utf8.count
                + arguments.utf8.count
                + 48
        )
    }

    /** Records the exact compact model-visible result envelope. */
    public func recordToolResult(iteration _: Int, callID: String, result: String) {
        append(
            .toolResult(id: callID, result: result),
            estimatedByteCount: callID.utf8.count + result.utf8.count + 32
        )
    }

    /** Returns a detached snapshot ordered by execution entry and iteration number. */
    public func transcript() -> LLMRunTranscript {
        LLMRunTranscript(
            entries: entries,
            iterationUsage: usageByIteration.keys.sorted().compactMap { iteration in
                usageByIteration[iteration].map {
                    LLMRunIterationUsage(iteration: iteration, usage: $0)
                }
            }
        )
    }

    /** Accepts a conservatively sized entry or stops all later text capture. */
    private func append(
        _ entry: LLMRunTranscriptEntry,
        estimatedByteCount: Int
    ) {
        guard !reachedCaptureLimit else { return }
        let normalizedCount = max(estimatedByteCount, 0)
        guard capturedByteCount <= Self.maximumCapturedByteCount - normalizedCount else {
            reachedCaptureLimit = true
            return
        }
        entries.append(entry)
        capturedByteCount += normalizedCount
    }

    /** Encodes one JSON value deterministically, falling back to an empty object only on failure. */
    private static func encodedString(_ value: JSONValue) -> String {
        guard let data = try? value.encodedData() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /** Returns the deterministic encoded byte count without retaining a second string. */
    private static func encodedByteCount(_ value: JSONValue) -> Int {
        (try? value.encodedData().count) ?? 2
    }
}
