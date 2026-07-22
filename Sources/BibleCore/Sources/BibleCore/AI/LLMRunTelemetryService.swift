// LLMRunTelemetryService.swift -- Android-compatible model usage and local raw-log persistence

import Foundation

/**
 Describes how one LLM run ended so local diagnostics preserve Android's error semantics.

 Values are metadata only. They carry no request headers, endpoints, or provider credentials and
 have no side effects.
 */
public enum LLMRunOutcome: Equatable, Sendable {
    /// The run produced a terminal result without an execution failure.
    case completed
    /// The run stopped because provider, parsing, tool, or persistence work failed.
    case failed
    /// The run stopped because the user or owning task cancelled execution.
    case cancelled
}

/**
 One structured entry in the provider-neutral transcript retained for local diagnostics.

 The cases intentionally exclude HTTP headers and credentials. Text values are formatted only when
 the complete transcript fits the service's byte ceiling; oversized input is rejected before any
 SwiftData insertion.
 */
public enum LLMRunTranscriptEntry: Equatable, Sendable {
    /// A conversation message with its provider-neutral role and optional content.
    case message(role: LLMRole, content: String?)
    /// A typed tool request with its provider call identity and raw JSON arguments.
    case toolCall(tool: AgentTool, id: String, arguments: String)
    /// A tool result associated with one provider call identity.
    case toolResult(id: String, result: String)
    /// The typed tool definitions supplied to the provider for one run.
    case toolDefinitions([LLMToolDefinition])
    /// A raw provider response or credential-free provider error for one iteration.
    case rawAPIResponse(iteration: Int, body: String)
}

/**
 Usage returned by one successful provider iteration in an LLM run.

 Iteration numbers are positive and unique within a transcript. Construction does not persist or
 aggregate usage; validation occurs when the transcript is stored.
 */
public struct LLMRunIterationUsage: Equatable, Sendable {
    /// One-based provider iteration number.
    public let iteration: Int
    /// Provider-neutral token counters returned by that iteration.
    public let usage: LLMUsage

    /**
     Creates one immutable iteration usage value.

     - Parameters:
       - iteration: One-based provider iteration number.
       - usage: Non-negative token counters returned by the provider.
     - Side effects: none.
     - Failure modes: Invalid or duplicate iteration numbers are rejected when persisted.
     */
    public init(iteration: Int, usage: LLMUsage) {
        self.iteration = iteration
        self.usage = usage
    }
}

/**
 Captures the ordered raw conversation and successful iteration usage for one LLM run.

 The value is detached from UI and SwiftData state. It intentionally has no credential, request
 header, or endpoint fields, preventing those values from entering the raw-log persistence API.
 */
public struct LLMRunTranscript: Equatable, Sendable {
    /// Entries retained in their exact execution order.
    public let entries: [LLMRunTranscriptEntry]
    /// Successful provider iteration counters used for raw-log totals and cost.
    public let iterationUsage: [LLMRunIterationUsage]

    /**
     Creates an immutable run transcript.

     - Parameters:
       - entries: Ordered provider-neutral messages, tools, and raw responses.
       - iterationUsage: Usage from each successful provider iteration.
     - Side effects: none.
     - Failure modes: Size and iteration invariants are validated before persistence.
     */
    public init(
        entries: [LLMRunTranscriptEntry],
        iterationUsage: [LLMRunIterationUsage] = []
    ) {
        self.entries = entries
        self.iterationUsage = iterationUsage
    }
}

/**
 Denormalized, credential-free metadata retained with one local raw transcript.

 Names and provider type remain readable after prompt, model, or provider deletion. The timestamp
 uses Android's epoch-millisecond representation and the outcome controls `wasError` parity.
 */
public struct LLMRunMetadata: Equatable, Sendable {
    /// Optional originating prompt identity.
    public let promptID: UUID?
    /// Prompt name retained after prompt deletion.
    public let promptName: String
    /// Prompt description retained after prompt deletion.
    public let promptDescription: String?
    /// Optional configured-model identity.
    public let configuredModelID: UUID?
    /// Provider model name retained after model deletion.
    public let modelName: String
    /// Android `LlmProvider` raw value retained after provider deletion.
    public let providerType: String
    /// Terminal event time as milliseconds since the Unix epoch.
    public let timestampMilliseconds: Int64
    /// Terminal run outcome used to distinguish successful logs from failures and cancellation.
    public let outcome: LLMRunOutcome

    /**
     Creates immutable metadata for one raw transcript.

     - Parameters:
       - promptID: Originating prompt identity, when one exists.
       - promptName: User-visible prompt name.
       - promptDescription: Optional prompt description.
       - configuredModelID: Effective configured-model identity, when resolution succeeded.
       - modelName: Provider model identifier used by the run.
       - providerType: Android provider raw value; never an API key or request header.
       - timestampMilliseconds: Terminal event time in Unix epoch milliseconds.
       - outcome: Completed, failed, or cancelled terminal state.
     - Side effects: none.
     - Failure modes: Oversized text metadata is rejected before persistence.
     */
    public init(
        promptID: UUID? = nil,
        promptName: String = "",
        promptDescription: String? = nil,
        configuredModelID: UUID? = nil,
        modelName: String = "",
        providerType: String = "",
        timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        outcome: LLMRunOutcome
    ) {
        self.promptID = promptID
        self.promptName = promptName
        self.promptDescription = promptDescription
        self.configuredModelID = configuredModelID
        self.modelName = modelName
        self.providerType = providerType
        self.timestampMilliseconds = timestampMilliseconds
        self.outcome = outcome
    }
}

/**
 Attributes one successful provider response to a configured model.

 The service resolves pricing from the persisted configured model and supplies the device identity;
 callers do not provide cost or any provider credential.
 */
public struct LLMUsageSample: Equatable, Sendable {
    /// Configured model receiving the cumulative usage increment.
    public let configuredModelID: UUID
    /// Provider-neutral token counters from one successful response.
    public let usage: LLMUsage

    /**
     Creates one immutable usage sample.

     - Parameters:
       - configuredModelID: Existing configured-model identity.
       - usage: Non-negative counters from one successful provider response.
     - Side effects: none.
     - Failure modes: Model existence and cumulative overflow are checked when recorded.
     */
    public init(configuredModelID: UUID, usage: LLMUsage) {
        self.configuredModelID = configuredModelID
        self.usage = usage
    }
}

/** Stable, credential-free failures raised by LLM telemetry persistence. */
public enum LLMRunTelemetryServiceError: Error, Equatable, LocalizedError, Sendable {
    /// The per-device cumulative row cannot use an empty or oversized device identifier.
    case invalidDeviceIdentifier
    /// A transcript contains a non-positive provider iteration number.
    case invalidIteration(Int)
    /// A transcript contains more than one usage value for the same provider iteration.
    case duplicateIteration(Int)
    /// Denormalized prompt or model metadata exceeds its durable byte ceiling.
    case metadataTooLarge(maximumByteCount: Int)
    /// Formatted transcript text exceeds its uncompressed byte ceiling.
    case transcriptTooLarge(maximumByteCount: Int)
    /// Gzip output exceeds its durable BLOB byte ceiling.
    case compressedLogTooLarge(maximumByteCount: Int)
    /// Existing and incremental token counters cannot be represented by `Int64`.
    case usageCounterOverflow
    /// The configured retention value cannot produce a representable epoch-millisecond cutoff.
    case retentionBoundaryOverflow
    /// The shared gzip encoder could not encode an otherwise valid transcript.
    case compressionFailed

    /// User-facing description that never embeds transcript text, metadata, or credentials.
    public var errorDescription: String? {
        switch self {
        case .invalidDeviceIdentifier:
            return "The device identifier is invalid for usage persistence."
        case .invalidIteration, .duplicateIteration:
            return "The run contains invalid iteration usage metadata."
        case .metadataTooLarge:
            return "The run metadata is too large to retain safely."
        case .transcriptTooLarge, .compressedLogTooLarge:
            return "The raw run log is too large to retain safely."
        case .usageCounterOverflow:
            return "The model usage counters exceed the supported range."
        case .retentionBoundaryOverflow:
            return "The raw-log retention boundary exceeds the supported range."
        case .compressionFailed:
            return "The raw run log could not be compressed."
        }
    }
}

/**
 Persists Android-compatible cumulative model usage and device-local raw LLM logs.

 Usage is written once per successful provider response into the configured-model/device row. Raw
 logs are a separate terminal operation so failed and cancelled runs retain completed iteration
 diagnostics without double-counting usage. Accepted transcripts use Android's readable headings,
 JSON formatting, gzip payload, and `wasError` mapping. Credentials cannot be supplied through any
 service metadata field, and hard byte ceilings bound every persisted text or BLOB payload.

 - Important: Main-actor isolation serializes access to the underlying `AISettingsStore`. Terminal
   raw-log persistence intentionally does not check task cancellation because Android saves the
   available transcript when a run is cancelled.
 */
@MainActor
public final class LLMRunTelemetryService {
    /// Maximum UTF-8 bytes accepted across denormalized text metadata.
    public static let maximumMetadataByteCount = 64 * 1_024
    /// Maximum UTF-8 bytes accepted for Android-formatted transcript text.
    public static let maximumTranscriptByteCount = 1 * 1_024 * 1_024
    /// Maximum gzip bytes accepted for the local raw-log BLOB.
    public static let maximumCompressedLogByteCount = maximumTranscriptByteCount + 64 * 1_024
    /// Maximum UTF-8 bytes accepted for the stable per-device identifier.
    public static let maximumDeviceIdentifierByteCount = 256

    /// Milliseconds in Android's retention-day calculation.
    private static let millisecondsPerDay: Int64 = 24 * 60 * 60 * 1_000

    /// Existing persistence contract for cumulative rows, settings, and local logs.
    private let settingsStore: AISettingsStore
    /// Stable local device identity used to isolate cumulative counters across sync peers.
    private let deviceID: String
    /// Epoch-millisecond source kept injectable for deterministic retention behavior.
    private let currentTimeMilliseconds: () -> Int64
    /// Shared gzip boundary kept injectable for deterministic compression-failure coverage.
    private let gzip: (Data) throws -> Data

    /**
     Creates a telemetry service using the shared gzip codec and wall-clock retention time.

     - Parameters:
       - settingsStore: Main-actor AI persistence store containing both AI model groups.
       - deviceID: Stable non-secret device identifier used by cumulative usage rows.
     - Side effects: Retains dependencies only; no SwiftData reads or writes occur.
     - Failure modes: Device identity is validated when usage is first recorded.
     */
    public convenience init(settingsStore: AISettingsStore, deviceID: String) {
        self.init(
            settingsStore: settingsStore,
            deviceID: deviceID,
            currentTimeMilliseconds: {
                Int64(Date().timeIntervalSince1970 * 1_000)
            },
            gzip: RemoteSyncArchiveStagingService.gzip
        )
    }

    /**
     Creates a telemetry service with deterministic time and compression boundaries.

     This initializer supports package tests while production uses the public convenience
     initializer. Supplied closures execute synchronously on the main actor.

     - Parameters:
       - settingsStore: AI persistence store used by every operation.
       - deviceID: Stable non-secret device identifier for cumulative rows.
       - currentTimeMilliseconds: Epoch-millisecond source for retention cleanup.
       - gzip: Encoder that returns one gzip member for bounded input bytes.
     - Side effects: Retains dependencies only.
     - Failure modes: Closure failures are surfaced by the operation that invokes them.
     */
    init(
        settingsStore: AISettingsStore,
        deviceID: String,
        currentTimeMilliseconds: @escaping () -> Int64,
        gzip: @escaping (Data) throws -> Data
    ) {
        self.settingsStore = settingsStore
        self.deviceID = deviceID
        self.currentTimeMilliseconds = currentTimeMilliseconds
        self.gzip = gzip
    }

    /**
     Adds one successful provider response to Android's per-device cumulative usage row.

     Cost uses all four persisted configured-model prices and token categories, expressed in USD per
     million tokens. The main actor serializes read-modify-write operations just as Android's mutex
     serializes its DAO updates.

     - Parameter sample: Existing configured model and one response's token counters.
     - Returns: Updated managed `LLMUsageRecord` for the configured model and this device.
     - Side effects: Reads model and usage rows, then inserts or updates and saves one usage row.
     - Throws: `AISettingsStoreError.modelNotFound`, `LLMRunTelemetryServiceError`, or SwiftData
       fetch/save errors. No partial counter update is saved when validation fails.
     */
    @discardableResult
    public func recordUsage(_ sample: LLMUsageSample) throws -> LLMUsageRecord {
        try validateDeviceIdentifier()
        guard let model = try settingsStore.model(id: sample.configuredModelID) else {
            throw AISettingsStoreError.modelNotFound(sample.configuredModelID)
        }
        if let existing = try settingsStore.usageRecords().first(where: {
            $0.configuredModelId == sample.configuredModelID && $0.deviceId == deviceID
        }) {
            try Self.validateAccumulation(existing: existing, increment: sample.usage)
        }
        return try settingsStore.recordUsage(
            sample.usage,
            configuredModelId: sample.configuredModelID,
            deviceId: deviceID,
            estimatedCostUSD: Self.estimatedCost(for: sample.usage, model: model)
        )
    }

    /**
     Compresses and inserts one non-empty terminal run transcript using Android's raw-log contract.

     Cache-token categories contribute to estimated cost but Android's raw-log row stores only total
     input and output counters. Failed and cancelled outcomes both set `wasError`; an empty transcript
     is skipped. This method deliberately completes after task cancellation so cancellation
     diagnostics are retained.

     - Parameters:
       - transcript: Ordered structured entries and successful per-iteration usage.
       - metadata: Credential-free denormalized run metadata and terminal outcome.
     - Returns: Inserted managed raw-log row, or `nil` when the transcript has no entries.
     - Side effects: Formats and compresses bounded data in memory, then inserts and saves one local
       `LLMRawLogRecord`.
     - Throws: `LLMRunTelemetryServiceError` for invalid, oversized, overflowing, or uncompressible
       input, plus SwiftData errors from insertion. No row is inserted before formatting succeeds.
     */
    @discardableResult
    public func persistRawLog(
        transcript: LLMRunTranscript,
        metadata: LLMRunMetadata
    ) throws -> LLMRawLogRecord? {
        guard !transcript.entries.isEmpty else { return nil }
        try Self.validateMetadata(metadata)
        let usage = try Self.aggregateUsage(transcript.iterationUsage)
        let formatted = try Self.format(transcript.entries)
        let rawData = Data(formatted.utf8)
        guard rawData.count <= Self.maximumTranscriptByteCount else {
            throw LLMRunTelemetryServiceError.transcriptTooLarge(
                maximumByteCount: Self.maximumTranscriptByteCount
            )
        }

        let compressed: Data
        do {
            compressed = try gzip(rawData)
        } catch {
            throw LLMRunTelemetryServiceError.compressionFailed
        }
        guard compressed.count <= Self.maximumCompressedLogByteCount else {
            throw LLMRunTelemetryServiceError.compressedLogTooLarge(
                maximumByteCount: Self.maximumCompressedLogByteCount
            )
        }

        let model = try metadata.configuredModelID.flatMap { try settingsStore.model(id: $0) }
        let record = LLMRawLogRecord(
            promptId: metadata.promptID,
            promptName: metadata.promptName,
            promptDescription: metadata.promptDescription,
            configuredModelId: metadata.configuredModelID,
            modelName: metadata.modelName,
            providerType: metadata.providerType,
            timestampMilliseconds: metadata.timestampMilliseconds,
            totalInputTokens: usage.inputTokens,
            totalOutputTokens: usage.outputTokens,
            estimatedCostUSD: model.map { Self.estimatedCost(for: usage, model: $0) } ?? 0,
            logData: compressed,
            iterationCount: transcript.iterationUsage.count,
            wasError: metadata.outcome != .completed
        )
        try settingsStore.insertRawLog(record)
        return record
    }

    /**
     Deletes local raw logs older than Android's configured retention boundary.

     A `nil` day count disables cleanup. Non-nil values use `now - days * 24h`, and records exactly
     on the cutoff are retained because Android deletes with a strict `<` comparison.

     - Returns: Number of rows whose timestamps were strictly older than the calculated cutoff.
     - Side effects: May create default global settings on first access; when retention is enabled,
       deletes matching local raw-log rows and saves the SwiftData context once.
     - Throws: `LLMRunTelemetryServiceError.retentionBoundaryOverflow` or SwiftData fetch/save errors.
     - Note: Time is sampled exactly once so cleanup is deterministic for a given clock value.
     */
    @discardableResult
    public func deleteExpiredRawLogs() throws -> Int {
        guard let retentionDays = try settingsStore.globalSettings().rawLogRetentionDays else {
            return 0
        }
        guard let days = Int64(exactly: retentionDays) else {
            throw LLMRunTelemetryServiceError.retentionBoundaryOverflow
        }
        let (retentionMilliseconds, multiplyOverflow) = days.multipliedReportingOverflow(
            by: Self.millisecondsPerDay
        )
        guard !multiplyOverflow else {
            throw LLMRunTelemetryServiceError.retentionBoundaryOverflow
        }
        let (cutoff, subtractOverflow) = currentTimeMilliseconds().subtractingReportingOverflow(
            retentionMilliseconds
        )
        guard !subtractOverflow else {
            throw LLMRunTelemetryServiceError.retentionBoundaryOverflow
        }

        let deletedCount = try settingsStore.rawLogs().filter {
            $0.timestampMilliseconds < cutoff
        }.count
        try settingsStore.deleteRawLogs(olderThan: cutoff)
        return deletedCount
    }

    /** Validates the durable device-key bound before any usage-row read or write. */
    private func validateDeviceIdentifier() throws {
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deviceID.utf8.count <= Self.maximumDeviceIdentifierByteCount else {
            throw LLMRunTelemetryServiceError.invalidDeviceIdentifier
        }
    }

    /** Rejects token additions that would trap or wrap the persisted `Int64` counters. */
    private static func validateAccumulation(
        existing: LLMUsageRecord,
        increment: LLMUsage
    ) throws {
        _ = try adding(existing.inputTokens, increment.inputTokens)
        _ = try adding(existing.outputTokens, increment.outputTokens)
        _ = try adding(existing.cacheCreationTokens, increment.cacheCreationTokens)
        _ = try adding(existing.cacheReadTokens, increment.cacheReadTokens)
    }

    /** Adds non-negative token counters and converts arithmetic overflow into a stable error. */
    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw LLMRunTelemetryServiceError.usageCounterOverflow }
        return sum
    }

    /** Aggregates unique positive iteration counters without allowing integer wraparound. */
    private static func aggregateUsage(_ iterations: [LLMRunIterationUsage]) throws -> LLMUsage {
        var seen: Set<Int> = []
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheCreationTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0

        for iteration in iterations {
            guard iteration.iteration > 0 else {
                throw LLMRunTelemetryServiceError.invalidIteration(iteration.iteration)
            }
            guard seen.insert(iteration.iteration).inserted else {
                throw LLMRunTelemetryServiceError.duplicateIteration(iteration.iteration)
            }
            inputTokens = try adding(inputTokens, iteration.usage.inputTokens)
            outputTokens = try adding(outputTokens, iteration.usage.outputTokens)
            cacheCreationTokens = try adding(
                cacheCreationTokens,
                iteration.usage.cacheCreationTokens
            )
            cacheReadTokens = try adding(cacheReadTokens, iteration.usage.cacheReadTokens)
        }
        return LLMUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    /** Calculates USD cost from persisted per-million prices while rejecting non-finite rates. */
    private static func estimatedCost(
        for usage: LLMUsage,
        model: LLMConfiguredModel
    ) -> Double {
        let pricedCounters: [(Int64, Double)] = [
            (usage.inputTokens, model.inputPricePerMillion),
            (usage.outputTokens, model.outputPricePerMillion),
            (usage.cacheCreationTokens, model.cacheCreationPricePerMillion),
            (usage.cacheReadTokens, model.cacheReadPricePerMillion),
        ]
        var perMillionTotal = 0.0
        for (tokens, rawPrice) in pricedCounters {
            let price = rawPrice.isFinite ? max(rawPrice, 0) : 0
            let component = Double(tokens) * price
            guard component.isFinite,
                  perMillionTotal <= Double.greatestFiniteMagnitude - component else {
                return .greatestFiniteMagnitude
            }
            perMillionTotal += component
        }
        let cost = perMillionTotal / 1_000_000
        return cost.isFinite ? cost : .greatestFiniteMagnitude
    }

    /** Enforces a combined UTF-8 ceiling across all denormalized metadata strings. */
    private static func validateMetadata(_ metadata: LLMRunMetadata) throws {
        var remaining = Self.maximumMetadataByteCount
        let values = [
            metadata.promptName,
            metadata.promptDescription ?? "",
            metadata.modelName,
            metadata.providerType,
        ]
        for value in values {
            let byteCount = value.utf8.count
            guard byteCount <= remaining else {
                throw LLMRunTelemetryServiceError.metadataTooLarge(
                    maximumByteCount: Self.maximumMetadataByteCount
                )
            }
            remaining -= byteCount
        }
    }

    /** Formats ordered entries with Android's `RawLlmLog.format()` headings and blank lines. */
    private static func format(_ entries: [LLMRunTranscriptEntry]) throws -> String {
        var output = BoundedTranscriptBuilder(maximumByteCount: maximumTranscriptByteCount)
        for entry in entries {
            switch entry {
            case .message(let role, let content):
                try output.append("=== \(role.rawValue.uppercased()) ===\n")
                try output.append(content ?? "(empty)")
                try output.append("\n\n")
            case .toolCall(let tool, let id, let arguments):
                try output.append("=== TOOL_CALL: \(tool.wireName) [\(id)] ===\n")
                try output.append(prettyFormattedJSON(arguments))
                try output.append("\n\n")
            case .toolResult(let id, let result):
                try output.append("=== TOOL_RESULT [\(id)] ===\n")
                try output.append(prettyFormattedJSON(result))
                try output.append("\n\n")
            case .toolDefinitions(let definitions):
                try output.append("=== TOOL DEFINITIONS (\(definitions.count) tools) ===\n")
                for definition in definitions {
                    try output.append("--- \(definition.tool.wireName) ---\n")
                    try output.append("Description: \(definition.description)\n")
                    let parameters = String(
                        decoding: try JSONValue.object(definition.parameters).encodedData(),
                        as: UTF8.self
                    )
                    try output.append("Parameters: \(prettyFormattedJSON(parameters))\n\n")
                }
            case .rawAPIResponse(let iteration, let body):
                try output.append("=== RAW API RESPONSE (iteration \(iteration)) ===\n")
                try output.append(prettyFormattedJSON(body))
                try output.append("\n\n")
            }
        }
        return output.value
    }

    /** Pretty-prints JSON objects/arrays and preserves malformed or scalar payloads verbatim. */
    private static func prettyFormattedJSON(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formattedData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return source
        }
        return unescapeLongJSONStringContents(String(decoding: formattedData, as: UTF8.self))
    }

    /**
     Converts escaped newlines and tabs inside long JSON string values into readable whitespace.

     Android applies the same display-only transformation after pretty printing. Matches are
     replaced from the end so UTF-16 ranges remain stable as escape pairs shrink.
     */
    private static func unescapeLongJSONStringContents(_ source: String) -> String {
        let pattern = #"\"((?:[^\"\\]|\\.){80,})\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement = result[range]
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\t"#, with: "\t")
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

/**
 Accumulates transcript chunks while enforcing an exact UTF-8 output ceiling.

 The builder stores only accepted chunks and joins them once, avoiding repeated whole-string copies.
 It is deterministic, performs no I/O, and throws before retaining a chunk that crosses the limit.
 */
private struct BoundedTranscriptBuilder {
    /// Maximum number of UTF-8 bytes that may be joined.
    private let maximumByteCount: Int
    /// Accepted output chunks in append order.
    private var chunks: [String] = []
    /// Cumulative UTF-8 bytes represented by `chunks`.
    private var byteCount = 0

    /** Creates an empty builder with a fixed byte ceiling. */
    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    /**
     Appends one chunk when its UTF-8 bytes fit within the remaining capacity.

     - Parameter chunk: Text to append without normalization.
     - Side effects: Appends to in-memory chunk storage and updates the byte count.
     - Throws: `LLMRunTelemetryServiceError.transcriptTooLarge` before mutation when the chunk would
       cross the configured ceiling.
     */
    mutating func append(_ chunk: String) throws {
        let chunkByteCount = chunk.utf8.count
        guard chunkByteCount <= maximumByteCount - byteCount else {
            throw LLMRunTelemetryServiceError.transcriptTooLarge(
                maximumByteCount: maximumByteCount
            )
        }
        chunks.append(chunk)
        byteCount += chunkByteCount
    }

    /// Joined transcript text; construction is bounded by `maximumByteCount` and cannot fail.
    var value: String { chunks.joined() }
}
