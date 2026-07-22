import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects Android's per-device usage accumulation and device-local raw-log persistence contracts.

 Tests use one in-memory AI schema, deterministic clocks, and the shared gzip codec. They perform no
 network, CloudKit, Keychain, or durable filesystem writes, and all SwiftData access remains on the
 main actor.
 */
@MainActor
final class LLMRunTelemetryServiceTests: XCTestCase {
    /**
     Verifies successful response usage accumulates independently per device and prices every token
     category from the configured model.

     Failure means synced cumulative counters could overwrite another device, lose cache usage, or
     diverge from Android's USD-per-million calculation.
     */
    func testUsageSamplesAccumulatePerDeviceWithConfiguredCost() throws {
        let store = AISettingsStore(modelContext: ModelContext(try makeContainer()))
        let model = try insertConfiguredModel(
            into: store,
            inputPrice: 2,
            outputPrice: 6,
            cacheCreationPrice: 3,
            cacheReadPrice: 0.5
        )
        let firstDevice = LLMRunTelemetryService(settingsStore: store, deviceID: "device-a")
        let secondDevice = LLMRunTelemetryService(settingsStore: store, deviceID: "device-b")

        try firstDevice.recordUsage(
            LLMUsageSample(
                configuredModelID: model.id,
                usage: LLMUsage(
                    inputTokens: 1_000_000,
                    outputTokens: 1_000_000,
                    cacheCreationTokens: 1_000_000,
                    cacheReadTokens: 1_000_000
                )
            )
        )
        try firstDevice.recordUsage(
            LLMUsageSample(
                configuredModelID: model.id,
                usage: LLMUsage(
                    inputTokens: 500_000,
                    outputTokens: 250_000,
                    cacheCreationTokens: 100_000,
                    cacheReadTokens: 200_000
                )
            )
        )
        try secondDevice.recordUsage(
            LLMUsageSample(
                configuredModelID: model.id,
                usage: LLMUsage(inputTokens: 25, outputTokens: 10)
            )
        )

        let records = try store.usageRecords()
        XCTAssertEqual(records.count, 2)
        let first = try XCTUnwrap(records.first { $0.deviceId == "device-a" })
        XCTAssertEqual(first.configuredModelId, model.id)
        XCTAssertEqual(first.inputTokens, 1_500_000)
        XCTAssertEqual(first.outputTokens, 1_250_000)
        XCTAssertEqual(first.cacheCreationTokens, 1_100_000)
        XCTAssertEqual(first.cacheReadTokens, 1_200_000)
        XCTAssertEqual(first.estimatedCostUSD, 14.4, accuracy: 0.000_000_1)

        let second = try XCTUnwrap(records.first { $0.deviceId == "device-b" })
        XCTAssertEqual(second.inputTokens, 25)
        XCTAssertEqual(second.outputTokens, 10)
        XCTAssertEqual(second.estimatedCostUSD, 0.000_11, accuracy: 0.000_000_001)

        XCTAssertThrowsError(
            try firstDevice.recordUsage(
                LLMUsageSample(configuredModelID: UUID(), usage: LLMUsage(inputTokens: 1))
            )
        ) { error in
            guard case AISettingsStoreError.modelNotFound = error else {
                return XCTFail("Expected missing configured-model failure, received \(error)")
            }
        }

        let overflowDevice = LLMRunTelemetryService(settingsStore: store, deviceID: "device-max")
        try overflowDevice.recordUsage(
            LLMUsageSample(
                configuredModelID: model.id,
                usage: LLMUsage(inputTokens: .max)
            )
        )
        XCTAssertThrowsError(
            try overflowDevice.recordUsage(
                LLMUsageSample(
                    configuredModelID: model.id,
                    usage: LLMUsage(inputTokens: 1)
                )
            )
        ) { error in
            XCTAssertEqual(error as? LLMRunTelemetryServiceError, .usageCounterOverflow)
        }
        let overflowRecord = try XCTUnwrap(
            try store.usageRecords().first { $0.deviceId == "device-max" }
        )
        XCTAssertEqual(overflowRecord.inputTokens, .max)
    }

    /**
     Verifies a completed run stores Android-formatted gzip text and denormalized summary metadata.

     Setup exercises every structured transcript entry and two usage iterations. Failure means raw
     log inspection, token totals, pricing, ordering, or post-deletion metadata would diverge from
     Android. The raw-log operation must not increment cumulative usage a second time.
     */
    func testCompletedRunStoresAndroidFormattedGzipPayloadAndMetadata() throws {
        let store = AISettingsStore(modelContext: ModelContext(try makeContainer()))
        let model = try insertConfiguredModel(
            into: store,
            inputPrice: 1,
            outputPrice: 2,
            cacheCreationPrice: 3,
            cacheReadPrice: 4
        )
        let promptID = UUID(uuidString: "4e70a6fb-fec4-4f46-b7d8-3e7f43285669")!
        let timestamp: Int64 = 1_721_234_567_890
        let service = LLMRunTelemetryService(settingsStore: store, deviceID: "device")
        let transcript = LLMRunTranscript(
            entries: [
                .message(role: .system, content: "System prompt"),
                .message(role: .user, content: "Explain Genesis 1:1"),
                .toolDefinitions([
                    LLMToolDefinition(
                        tool: .searchBible,
                        description: "Search verses",
                        parameters: [
                            "query": .object(["type": .string("string")]),
                        ]
                    ),
                ]),
                .rawAPIResponse(iteration: 1, body: #"{"choices":[]}"#),
                .toolCall(tool: .searchBible, id: "call-1", arguments: #"{"query":"light"}"#),
                .toolResult(id: "call-1", result: #"{"result":"Genesis 1:3"}"#),
                .message(role: .assistant, content: nil),
            ],
            iterationUsage: [
                LLMRunIterationUsage(
                    iteration: 1,
                    usage: LLMUsage(
                        inputTokens: 1_000_000,
                        outputTokens: 1_000_000,
                        cacheCreationTokens: 1_000_000,
                        cacheReadTokens: 1_000_000
                    )
                ),
                LLMRunIterationUsage(
                    iteration: 2,
                    usage: LLMUsage(
                        inputTokens: 1_000_000,
                        outputTokens: 1_000_000,
                        cacheCreationTokens: 1_000_000,
                        cacheReadTokens: 1_000_000
                    )
                ),
            ]
        )
        let metadata = LLMRunMetadata(
            promptID: promptID,
            promptName: "Explain",
            promptDescription: "Explain a selected passage",
            configuredModelID: model.id,
            modelName: model.modelId,
            providerType: LLMProvider.openAI.rawValue,
            timestampMilliseconds: timestamp,
            outcome: .completed
        )

        let inserted = try XCTUnwrap(
            service.persistRawLog(transcript: transcript, metadata: metadata)
        )
        let records = try store.rawLogs()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, inserted.id)
        XCTAssertEqual(inserted.promptId, promptID)
        XCTAssertEqual(inserted.promptName, "Explain")
        XCTAssertEqual(inserted.promptDescription, "Explain a selected passage")
        XCTAssertEqual(inserted.configuredModelId, model.id)
        XCTAssertEqual(inserted.modelName, "telemetry-model")
        XCTAssertEqual(inserted.providerType, "OPENAI")
        XCTAssertEqual(inserted.timestampMilliseconds, timestamp)
        XCTAssertEqual(inserted.totalInputTokens, 2_000_000)
        XCTAssertEqual(inserted.totalOutputTokens, 2_000_000)
        XCTAssertEqual(inserted.estimatedCostUSD, 20, accuracy: 0.000_000_1)
        XCTAssertEqual(inserted.iterationCount, 2)
        XCTAssertFalse(inserted.wasError)
        XCTAssertEqual(Data(inserted.logData.prefix(2)), Data([0x1f, 0x8b]))
        XCTAssertTrue(try store.usageRecords().isEmpty)

        let formatted = String(
            decoding: try gunzipTestData(inserted.logData),
            as: UTF8.self
        )
        let systemRange = try XCTUnwrap(formatted.range(of: "=== SYSTEM ===\nSystem prompt"))
        let userRange = try XCTUnwrap(formatted.range(of: "=== USER ===\nExplain Genesis 1:1"))
        let definitionsRange = try XCTUnwrap(
            formatted.range(of: "=== TOOL DEFINITIONS (1 tools) ===")
        )
        let responseRange = try XCTUnwrap(
            formatted.range(of: "=== RAW API RESPONSE (iteration 1) ===")
        )
        let callRange = try XCTUnwrap(
            formatted.range(of: "=== TOOL_CALL: searchBible [call-1] ===")
        )
        let resultRange = try XCTUnwrap(
            formatted.range(of: "=== TOOL_RESULT [call-1] ===")
        )
        XCTAssertLessThan(systemRange.lowerBound, userRange.lowerBound)
        XCTAssertLessThan(userRange.lowerBound, definitionsRange.lowerBound)
        XCTAssertLessThan(definitionsRange.lowerBound, responseRange.lowerBound)
        XCTAssertLessThan(responseRange.lowerBound, callRange.lowerBound)
        XCTAssertLessThan(callRange.lowerBound, resultRange.lowerBound)
        XCTAssertTrue(formatted.contains("--- searchBible ---"))
        XCTAssertTrue(formatted.contains("Description: Search verses"))
        XCTAssertTrue(formatted.contains("Parameters: {"))
        XCTAssertTrue(formatted.contains("=== ASSISTANT ===\n(empty)"))
    }

    /**
     Verifies failed and cancelled runs retain partial diagnostics and both map to Android's error
     flag, even when the caller's Swift task is already cancelled.

     The cancelled task performs no suspension between cancellation and persistence, making the
     assertion deterministic. Failure means cancellation could erase the only available provider
     response or be displayed as a successful run.
     */
    func testFailedAndCancelledRunsPersistPartialLogsAfterTaskCancellation() async throws {
        let store = AISettingsStore(modelContext: ModelContext(try makeContainer()))
        let service = LLMRunTelemetryService(settingsStore: store, deviceID: "device")
        let partialTranscript = LLMRunTranscript(
            entries: [
                .message(role: .user, content: "Question"),
                .rawAPIResponse(iteration: 1, body: "ERROR: request timed out"),
            ]
        )
        let failed = try XCTUnwrap(
            service.persistRawLog(
                transcript: partialTranscript,
                metadata: LLMRunMetadata(
                    promptName: "Failed run",
                    timestampMilliseconds: 100,
                    outcome: .failed
                )
            )
        )

        let cancelledTask = Task { @MainActor () throws -> (id: UUID, wasError: Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            guard let record = try service.persistRawLog(
                transcript: partialTranscript,
                metadata: LLMRunMetadata(
                    promptName: "Cancelled run",
                    timestampMilliseconds: 200,
                    outcome: .cancelled
                )
            ) else {
                throw CancellationPersistenceTestError.missingRecord
            }
            return (record.id, record.wasError)
        }
        let cancelled = try await cancelledTask.value

        XCTAssertTrue(failed.wasError)
        XCTAssertTrue(cancelled.wasError)
        XCTAssertEqual(failed.iterationCount, 0)
        let records = try store.rawLogs()
        XCTAssertEqual(records.map(\.promptName), ["Cancelled run", "Failed run"])
        XCTAssertEqual(records.first?.id, cancelled.id)
        XCTAssertEqual(records.first?.iterationCount, 0)

        let skipped = try service.persistRawLog(
            transcript: LLMRunTranscript(entries: []),
            metadata: LLMRunMetadata(promptName: "Empty", outcome: .cancelled)
        )
        XCTAssertNil(skipped)
        XCTAssertEqual(try store.rawLogs().count, 2)
    }

    /**
     Verifies retention disabling and Android's strict older-than boundary using a fixed clock.

     Logs one millisecond before, exactly on, and one millisecond after the cutoff avoid timing and
     calendar assumptions. Failure means cleanup could delete a boundary record or ignore the
     user's keep-all setting.
     */
    func testRetentionUsesStrictEpochBoundaryAndNilDisablesDeletion() throws {
        let now: Int64 = 10 * 24 * 60 * 60 * 1_000
        let retentionDays = 2
        let cutoff = now - Int64(retentionDays * 24 * 60 * 60 * 1_000)
        let store = AISettingsStore(modelContext: ModelContext(try makeContainer()))
        let settings = try store.globalSettings()
        settings.rawLogRetentionDays = nil
        try store.save()
        let service = LLMRunTelemetryService(
            settingsStore: store,
            deviceID: "device",
            currentTimeMilliseconds: { now },
            gzip: RemoteSyncArchiveStagingService.gzip
        )
        let oldID = UUID()
        let boundaryID = UUID()
        let recentID = UUID()
        try store.insertRawLog(
            rawLog(id: oldID, timestampMilliseconds: cutoff - 1)
        )
        try store.insertRawLog(
            rawLog(id: boundaryID, timestampMilliseconds: cutoff)
        )
        try store.insertRawLog(
            rawLog(id: recentID, timestampMilliseconds: cutoff + 1)
        )

        XCTAssertEqual(try service.deleteExpiredRawLogs(), 0)
        XCTAssertEqual(try store.rawLogs().count, 3)

        settings.rawLogRetentionDays = retentionDays
        try store.save()
        XCTAssertEqual(try service.deleteExpiredRawLogs(), 1)
        let retainedIDs = Set(try store.rawLogs().map(\.id))
        XCTAssertEqual(retainedIDs, [boundaryID, recentID])
        XCTAssertFalse(retainedIDs.contains(oldID))
    }

    /**
     Verifies byte-limit and gzip failures occur before a local raw-log row is inserted.

     The oversized input is one byte beyond the public ceiling, and the encoder failure uses a
     deterministic stub. Failure means malformed telemetry could consume unbounded local storage or
     leave a partial SwiftData record.
     */
    func testPayloadAndCompressionFailuresDoNotInsertRawLogs() throws {
        let store = AISettingsStore(modelContext: ModelContext(try makeContainer()))
        let service = LLMRunTelemetryService(settingsStore: store, deviceID: "device")
        let oversizedMetadata = String(
            repeating: "m",
            count: LLMRunTelemetryService.maximumMetadataByteCount + 1
        )
        XCTAssertThrowsError(
            try service.persistRawLog(
                transcript: LLMRunTranscript(
                    entries: [.message(role: .user, content: "Bounded")]
                ),
                metadata: LLMRunMetadata(
                    promptName: oversizedMetadata,
                    outcome: .failed
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMRunTelemetryServiceError,
                .metadataTooLarge(
                    maximumByteCount: LLMRunTelemetryService.maximumMetadataByteCount
                )
            )
        }

        let oversized = LLMRunTranscript(
            entries: [
                .message(
                    role: .user,
                    content: String(
                        repeating: "x",
                        count: LLMRunTelemetryService.maximumTranscriptByteCount + 1
                    )
                ),
            ]
        )

        XCTAssertThrowsError(
            try service.persistRawLog(
                transcript: oversized,
                metadata: LLMRunMetadata(promptName: "Oversized", outcome: .failed)
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMRunTelemetryServiceError,
                .transcriptTooLarge(
                    maximumByteCount: LLMRunTelemetryService.maximumTranscriptByteCount
                )
            )
        }

        let failingService = LLMRunTelemetryService(
            settingsStore: store,
            deviceID: "device",
            currentTimeMilliseconds: { 0 },
            gzip: { _ in throw CompressionStubError.failed }
        )
        XCTAssertThrowsError(
            try failingService.persistRawLog(
                transcript: LLMRunTranscript(
                    entries: [.message(role: .user, content: "Bounded")]
                ),
                metadata: LLMRunMetadata(promptName: "Compression", outcome: .failed)
            )
        ) { error in
            XCTAssertEqual(error as? LLMRunTelemetryServiceError, .compressionFailed)
        }

        let oversizedCompressionService = LLMRunTelemetryService(
            settingsStore: store,
            deviceID: "device",
            currentTimeMilliseconds: { 0 },
            gzip: { _ in
                Data(
                    repeating: 0,
                    count: LLMRunTelemetryService.maximumCompressedLogByteCount + 1
                )
            }
        )
        XCTAssertThrowsError(
            try oversizedCompressionService.persistRawLog(
                transcript: LLMRunTranscript(
                    entries: [.message(role: .user, content: "Bounded")]
                ),
                metadata: LLMRunMetadata(promptName: "Compression size", outcome: .failed)
            )
        ) { error in
            XCTAssertEqual(
                error as? LLMRunTelemetryServiceError,
                .compressedLogTooLarge(
                    maximumByteCount: LLMRunTelemetryService.maximumCompressedLogByteCount
                )
            )
        }
        XCTAssertTrue(try store.rawLogs().isEmpty)
    }

    /**
     Builds an isolated SwiftData container with exactly the AI model registration groups.

     - Returns: Empty in-memory container with syncable and local-only AI schemas registered.
     - Side effects: Allocates transient in-memory SwiftData state; no durable files are created.
     - Throws: `ModelContainer` initialization errors when the schema cannot be loaded.
     */
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(
            AIModelRegistration.cloudSyncableModels + AIModelRegistration.localOnlyModels
        )
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Inserts one OpenAI provider and configured model with explicit test pricing.

     - Parameters:
       - store: In-memory settings store receiving both rows.
       - inputPrice: Input-token USD price per million.
       - outputPrice: Output-token USD price per million.
       - cacheCreationPrice: Cache-creation USD price per million.
       - cacheReadPrice: Cache-read USD price per million.
     - Returns: Saved configured model used by telemetry operations.
     - Side effects: Inserts and saves one provider row and one configured-model row.
     - Throws: SwiftData insertion or save errors.
     */
    private func insertConfiguredModel(
        into store: AISettingsStore,
        inputPrice: Double,
        outputPrice: Double,
        cacheCreationPrice: Double,
        cacheReadPrice: Double
    ) throws -> LLMConfiguredModel {
        let provider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(
            providerConfigId: provider.id,
            modelId: "telemetry-model",
            inputPricePerMillion: inputPrice,
            outputPricePerMillion: outputPrice,
            cacheCreationPricePerMillion: cacheCreationPrice,
            cacheReadPricePerMillion: cacheReadPrice
        )
        try store.insertModel(model)
        return model
    }

    /**
     Creates an unmanaged minimal raw-log row for deterministic retention setup.

     - Parameters:
       - id: Stable identity used by boundary assertions.
       - timestampMilliseconds: Exact epoch-millisecond retention position.
     - Returns: Raw-log row with a minimal gzip signature payload.
     - Side effects: none; callers explicitly insert the returned row.
     */
    private func rawLog(id: UUID, timestampMilliseconds: Int64) -> LLMRawLogRecord {
        LLMRawLogRecord(
            id: id,
            promptName: "Retention",
            timestampMilliseconds: timestampMilliseconds,
            logData: Data([0x1f, 0x8b])
        )
    }
}

/** Deterministic compression failure emitted by the test-only encoder closure. */
private enum CompressionStubError: Error {
    /// Indicates the stub rejected its bounded input without side effects.
    case failed
}

/** Failure emitted when a non-empty cancellation transcript is unexpectedly skipped. */
private enum CancellationPersistenceTestError: Error {
    /// Indicates the service returned no row for a non-empty cancelled transcript.
    case missingRecord
}
