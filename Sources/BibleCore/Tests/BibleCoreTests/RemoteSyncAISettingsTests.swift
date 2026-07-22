import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

/// Deterministic interruption injected after remote publication but before local outbox acceptance.
private enum SimulatedAISettingsAcceptanceError: Error, Equatable {
    /// Represents a process failure at the final local acceptance boundary.
    case interruptedBeforeAcceptance
}

/// Deterministic strict-secret backend failure used to prove snapshot publication fails closed.
private enum SimulatedAICredentialLookupError: Error, Equatable {
    /// Represents a Keychain access failure that must not be interpreted as a missing credential.
    case unavailable
}

/**
 Creates an AI settings projector that deterministically reports no device-local credentials.

 - Returns: Strict snapshot service suitable for credential-free synchronization fixtures.
 - Side effects: none.
 - Failure modes: The injected lookup does not throw.
 */
private func makeCredentialFreeAISettingsSnapshotService() -> RemoteSyncAISettingsSnapshotService {
    RemoteSyncAISettingsSnapshotService(credentialForProvider: { _ in nil })
}

/**
 Secret-store double whose compatibility lookup collapses failure while strict lookup preserves it.

 The mismatch models production Keychain compatibility behavior and proves AI sync selects the
 strict capability. It stores no values and performs no filesystem, Keychain, or network work.
 */
private final class StrictReadFailingAISecretStore: SecretStoring, StrictSecretReading {
    /** Returns `nil` to model the legacy compatibility lookup's fail-open shape. */
    func secret(forKey key: String) -> String? {
        nil
    }

    /** Throws the deterministic backend error expected to abort synchronized snapshot projection. */
    func secretStrict(forKey key: String) throws -> String? {
        throw SimulatedAICredentialLookupError.unavailable
    }

    /** Rejects unexpected writes because this fixture is read-only. */
    func setSecret(_ value: String, forKey key: String) throws {
        XCTFail("Strict-read failure fixture must not receive writes")
    }

    /** Rejects unexpected deletes because this fixture is read-only. */
    func removeSecret(forKey key: String) throws {
        XCTFail("Strict-read failure fixture must not receive deletes")
    }
}

/// Local fixture identities shared by the Android v23 AI settings round-trip assertions.
private struct AISettingsSyncFixtureIDs {
    let provider: UUID
    let configuredModel: UUID
    let agentPrompt: UUID
    let usageRecord: UUID
    let promptCategory: UUID
    let builtinOverride: UUID
    let rawLog: UUID
}

/**
 Protects Android v23 AI settings remote-sync behavior across SQLite publication and SwiftData replay.

 The suite uses in-memory SwiftData stores, temporary SQLite/gzip files, an in-memory credential
 backend, and an in-memory remote adapter. It performs no network, CloudKit, Keychain, or durable
 user-data writes. Every test anchors Android's seven-table `AI_SETTINGS` contract while proving raw
 logs and credentials remain device-local.
 */
@MainActor
final class RemoteSyncAISettingsTests: XCTestCase {
    /**
     Proves all seven Android-synchronized tables survive a full writer/read/restore cycle exactly.

     The source also contains a raw model log and provider credential, while the destination starts
     with a different raw log, credential, and stale synchronized row. A successful result requires
     all seven synchronized rows to replace the stale graph, an empty outbound raw-log table, no
     secret or local raw payload bytes in iOS output, bounded ignoring of one Android-origin raw log,
     and preservation of destination-local state. A failure indicates data loss, secret leakage, or
     drift from Android's v23 initial-backup contract.
     */
    func testAndroidV23DatabaseRoundTripRestoresAllSynchronizedTablesAndPreservesLocalState() throws {
        let sourceContainer = try makeAISettingsSyncContainer()
        let sourceContext = ModelContext(sourceContainer)
        let sourceSettingsStore = SettingsStore(modelContext: sourceContext)
        let fixtureIDs = try insertCompleteAISettingsFixture(into: sourceContext)
        let secretStore = InMemorySecretStore()
        let credentialStore = AICredentialStore(secretStore: secretStore)
        let credential = "test-only-provider-secret-7d873b"
        try credentialStore.setCredential(credential, for: fixtureIDs.provider)

        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { credentialStore.credential(for: $0) }
        )
        let sourceSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        let directoryURL = try makeAISettingsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let databaseURL = directoryURL.appendingPathComponent("ai_settings.sqlite3")

        let writeReport = try RemoteSyncAISettingsDatabaseWriter().writeFullDatabase(
            at: databaseURL,
            snapshot: sourceSnapshot
        )

        XCTAssertEqual(writeReport.schemaVersion, 23)
        XCTAssertEqual(writeReport.providerCount, 1)
        XCTAssertEqual(writeReport.configuredModelCount, 1)
        XCTAssertEqual(writeReport.agentPromptCount, 1)
        XCTAssertEqual(writeReport.globalSettingsCount, 1)
        XCTAssertEqual(writeReport.usageRecordCount, 1)
        XCTAssertEqual(writeReport.promptCategoryCount, 1)
        XCTAssertEqual(writeReport.builtinPromptOverrideCount, 1)
        XCTAssertEqual(writeReport.logEntryCount, 0)
        XCTAssertEqual(writeReport.rawLogRecordCount, 0)
        XCTAssertEqual(
            try sqliteInteger("SELECT COUNT(*) FROM LlmRawLogRecord;", databaseURL: databaseURL),
            0
        )

        let databaseData = try Data(contentsOf: databaseURL)
        XCTAssertNil(databaseData.range(of: Data(credential.utf8)))
        XCTAssertNil(databaseData.range(of: Data("source-device-local-raw-log".utf8)))
        try insertAndroidRawLogFixture(into: databaseURL)

        let restoreService = RemoteSyncAISettingsRestoreService()
        let decodedSnapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(Set(decodedSnapshot.providers.map(\.id)), [fixtureIDs.provider])
        XCTAssertEqual(Set(decodedSnapshot.configuredModels.map(\.id)), [fixtureIDs.configuredModel])
        XCTAssertEqual(Set(decodedSnapshot.agentPrompts.map(\.id)), [fixtureIDs.agentPrompt])
        XCTAssertEqual(decodedSnapshot.globalSettings.map(\.id), [GlobalAISettings.singletonID])
        XCTAssertEqual(Set(decodedSnapshot.usageRecords.map(\.id)), [fixtureIDs.usageRecord])
        XCTAssertEqual(Set(decodedSnapshot.promptCategories.map(\.id)), [fixtureIDs.promptCategory])
        XCTAssertEqual(Set(decodedSnapshot.builtinOverrides.map(\.id)), [fixtureIDs.builtinOverride])
        XCTAssertEqual(decodedSnapshot.ignoredIncomingRawLogCount, 1)

        let destinationContainer = try makeAISettingsSyncContainer()
        let destinationContext = ModelContext(destinationContainer)
        let destinationSettingsStore = SettingsStore(modelContext: destinationContext)
        let staleProviderID = UUID(uuidString: "a2000000-0000-0000-0000-000000000099")!
        destinationContext.insert(
            LLMProviderConfig(
                id: staleProviderID,
                provider: .openAI,
                displayName: "Stale provider"
            )
        )
        let localRawLog = LLMRawLogRecord(
            id: UUID(uuidString: "a8000000-0000-0000-0000-000000000099")!,
            promptName: "Destination local log",
            modelName: "local-model",
            providerType: "OPENAI",
            timestampMilliseconds: 999,
            logData: Data("destination-device-local-raw-log".utf8)
        )
        destinationContext.insert(localRawLog)
        try destinationContext.save()
        let destinationSecrets = InMemorySecretStore()
        let destinationCredentials = AICredentialStore(secretStore: destinationSecrets)
        try destinationCredentials.setCredential("destination-local-secret", for: fixtureIDs.provider)

        let restoreReport = try restoreService.restore(
            from: databaseURL,
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )

        XCTAssertEqual(restoreReport.restoredProviderCount, 1)
        XCTAssertEqual(restoreReport.restoredConfiguredModelCount, 1)
        XCTAssertEqual(restoreReport.restoredAgentPromptCount, 1)
        XCTAssertEqual(restoreReport.restoredGlobalSettingsCount, 1)
        XCTAssertEqual(restoreReport.restoredUsageRecordCount, 1)
        XCTAssertEqual(restoreReport.restoredPromptCategoryCount, 1)
        XCTAssertEqual(restoreReport.restoredBuiltinPromptOverrideCount, 1)
        XCTAssertEqual(restoreReport.ignoredIncomingRawLogCount, 1)
        XCTAssertEqual(restoreReport.preservedLocalRawLogCount, 1)
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [localRawLog.id]
        )
        XCTAssertEqual(
            destinationCredentials.credential(for: fixtureIDs.provider),
            "destination-local-secret"
        )
        XCTAssertFalse(
            try destinationContext.fetch(FetchDescriptor<LLMProviderConfig>())
                .contains(where: { $0.id == staleProviderID })
        )

        let restoredSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        XCTAssertEqual(restoredSnapshot, sourceSnapshot)
    }

    /**
     Verifies raw-log and credential-only changes are invisible to both snapshots and mutation logs.

     An accepted empty baseline is established before writing one Keychain-shaped credential and one
     local raw log. Neither may create an AI sync operation. A later provider insert must create
     exactly one provider UPSERT, proving the empty journal was caused by exclusion rather than a
     disabled journal. A failure means device-local or secret state can leak into remote sync.
     */
    func testRawLogsAndCredentialsAreExcludedFromSnapshotsAndMutationJournal() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let secrets = InMemorySecretStore()
        let credentialStore = AICredentialStore(secretStore: secrets)
        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { credentialStore.credential(for: $0) }
        )
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let providerID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!
        try credentialStore.setCredential("never-sync-this-secret", for: providerID)
        let aiStore = AISettingsStore(
            modelContext: modelContext,
            remoteSyncSnapshotService: snapshotService
        )
        try aiStore.insertRawLog(
            LLMRawLogRecord(
                id: UUID(uuidString: "b8000000-0000-0000-0000-000000000001")!,
                promptName: "Local-only",
                modelName: "device-model",
                providerType: "CUSTOM",
                timestampMilliseconds: 10,
                logData: Data("never-sync-this-log".utf8)
            )
        )

        let localOnlySnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(localOnlySnapshot.providerRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.configuredModelRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.agentPromptRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.globalSettingsRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.usageRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.promptCategoryRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.builtinOverrideRowsByKey.isEmpty)
        XCTAssertTrue(localOnlySnapshot.fingerprintsByKey.isEmpty)
        XCTAssertTrue(
            try RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings)
                .isEmpty
        )
        XCTAssertTrue(
            try RemoteSyncMutationJournalService(aiSettingsSnapshotService: snapshotService)
                .pendingMutations(for: .aiSettings, settingsStore: settingsStore)
                .isEmpty
        )
        XCTAssertEqual(credentialStore.credential(for: providerID), "never-sync-this-secret")

        try aiStore.insertProvider(
            LLMProviderConfig(
                id: providerID,
                provider: .custom,
                displayName: "Synchronized provider",
                endpoint: "https://example.invalid/v1",
                apiFormat: .openAI
            )
        )

        let entries = try RemoteSyncLogEntryStore(settingsStore: settingsStore)
            .entriesStrict(for: .aiSettings)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.tableName, "LlmProviderConfig")
        XCTAssertEqual(entries.first?.type, .upsert)
        XCTAssertFalse(entries.contains(where: { $0.tableName == "LlmRawLogRecord" }))
        let pending = try RemoteSyncMutationJournalService(
            aiSettingsSnapshotService: snapshotService
        )
            .pendingMutations(for: .aiSettings, settingsStore: settingsStore)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.values.first?.entry.tableName, "LlmProviderConfig")
    }

    /**
     Verifies custom endpoint routing survives sync while credential-bearing endpoint forms fail closed.

     Android stores custom endpoint queries as ordinary provider state, so benign deployment routing
     must remain serializable. User-info, signed URL fields, OAuth codes, recognizable opaque tokens,
     credential-bearing path labels, and the exact device-local Keychain value must fail before
     snapshot publication.
     */
    func testEndpointPolicyPreservesRoutingQueriesWithoutSerializingCredentials() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "b2000000-0000-0000-0000-000000000002")!
        let localCredential = "device-local-provider-secret"
        let provider = LLMProviderConfig(
            id: providerID,
            provider: .custom,
            displayName: "Query-routed provider",
            endpoint: "https://llm.example.invalid/v1?region=eu&deployment=study",
            apiFormat: .openAI
        )
        modelContext.insert(provider)
        try modelContext.save()
        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { id in id == providerID ? localCredential : nil }
        )

        let safeSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(
            safeSnapshot.providerRowsByKey.values.first?.endpoint,
            "https://llm.example.invalid/v1?region=eu&deployment=study"
        )

        provider.endpoint = "https://llm.example.invalid/proxy/\(localCredential)/v1"
        XCTAssertThrowsError(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAISettingsSnapshotError,
                .unsafeSynchronizedEndpoint(providerID: providerID)
            )
        }

        let unsafeEndpoints = [
            "https://llm.example.invalid/v1?api_key=remote-secret",
            "https://llm.example.invalid/v1?X-Amz-Credential=remote-secret",
            "https://llm.example.invalid/v1?X-Amz-Signature=remote-signature",
            "https://llm.example.invalid/v1?x-goog-signature=remote-signature",
            "https://llm.example.invalid/v1?code=oauth-code",
            "https://llm.example.invalid/credential/remote-secret/v1",
            "https://llm.example.invalid/v1?deployment=sk-remote-secret-value-1234567890",
            "https://llm.example.invalid/v1?deployment=sk%252Dremote%252Dsecret%252Dvalue%252D1234567890",
            "https://llm.example.invalid/v1?deployment=device%252Dlocal%252Dprovider%252Dsecret",
        ]
        for unsafeEndpoint in unsafeEndpoints {
            provider.endpoint = unsafeEndpoint
            XCTAssertThrowsError(
                try snapshotService.snapshotCurrentStateStrict(
                    modelContext: modelContext,
                    settingsStore: settingsStore
                ),
                "Accepted credential-bearing endpoint: \(unsafeEndpoint)"
            ) { error in
                XCTAssertEqual(
                    error as? RemoteSyncAISettingsSnapshotError,
                    .unsafeSynchronizedEndpoint(providerID: providerID)
                )
            }
        }

        let benignRoutingValues = [
            "aiza-route",
            "akia-route",
            "github_pat_route",
            "ghp_route",
            "rk-route",
            "sk-route",
            "sk_route",
            "xoxa-route",
            "xoxb-route",
            "xoxp-route",
            "xoxr-route",
            "xoxs-route",
        ]
        for routingValue in benignRoutingValues {
            provider.endpoint = "https://llm.example.invalid/\(routingValue)/v1?deployment=\(routingValue)"
            XCTAssertNoThrow(
                try snapshotService.snapshotCurrentStateStrict(
                    modelContext: modelContext,
                    settingsStore: settingsStore
                ),
                "Rejected benign routing label: \(routingValue)"
            )
        }
        provider.endpoint = "https://sk-provider-routing-name-that-is-not-a-token.example.invalid/v1"
        XCTAssertNoThrow(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        )
    }

    /**
     Verifies strict credential lookup failures abort projection instead of enabling publication.

     The injected backend deliberately returns `nil` through the compatibility read but throws from
     its strict read, mirroring a Keychain access failure such as `errSecInteractionNotAllowed`.
     Snapshot projection must surface a provider-scoped typed failure before endpoint bytes can reach
     either a full or sparse Android database writer. The in-memory store performs no durable writes.
     */
    func testCredentialLookupFailureAbortsSnapshotProjection() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "b2000000-0000-0000-0000-000000000003")!
        modelContext.insert(
            LLMProviderConfig(
                id: providerID,
                provider: .custom,
                displayName: "Unavailable credential backend",
                endpoint: "https://llm.example.invalid/v1?deployment=u7KM3rQ9Zp2V5nX8",
                apiFormat: .openAI
            )
        )
        try modelContext.save()
        let credentialStore = AICredentialStore(
            secretStore: StrictReadFailingAISecretStore()
        )
        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { try credentialStore.credentialStrict(for: $0) }
        )

        XCTAssertThrowsError(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAISettingsSnapshotError,
                .credentialLookupFailed(providerID: providerID)
            )
        }
    }

    /**
     Protects Android's strict `incoming.lastUpdated > local.lastUpdated` conflict rule.

     The first remote provider UPSERT has an equal timestamp and must be skipped regardless of its
     source device. A second otherwise-identical UPSERT is one millisecond newer and must replace the
     local row. Failure means iOS has introduced a source-device tie-break or weakened Android's
     whole-row last-write conflict contract.
     */
    func testPatchConflictAcceptsOnlyStrictlyGreaterLastUpdated() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "c2000000-0000-0000-0000-000000000001")!
        modelContext.insert(
            LLMProviderConfig(
                id: providerID,
                provider: .openAI,
                displayName: "Local provider"
            )
        )
        try modelContext.save()
        RemoteSyncLogEntryStore(settingsStore: settingsStore).addEntry(
            aiSettingsLogEntry(
                tableName: "LlmProviderConfig",
                id: providerID,
                type: .upsert,
                lastUpdated: 500,
                sourceDevice: "ios-device"
            ),
            for: .aiSettings
        )

        let remoteSnapshot = try makeProviderSnapshot(
            id: providerID,
            displayName: "Remote provider"
        )
        let equalArchive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: providerID,
                    type: .upsert,
                    lastUpdated: 500,
                    sourceDevice: "android-z"
                )
            ],
            sourceDevice: "android-z",
            patchNumber: 1,
            fileTimestamp: 500
        )
        defer { try? FileManager.default.removeItem(at: equalArchive.archiveFileURL) }

        let applyService = RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        )
        let equalReport = try applyService.applyPatchArchives(
            [equalArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(equalReport.appliedLogEntryCount, 0)
        XCTAssertEqual(equalReport.skippedLogEntryCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(modelContext.fetch(FetchDescriptor<LLMProviderConfig>()).first).displayName,
            "Local provider"
        )

        let newerArchive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: providerID,
                    type: .upsert,
                    lastUpdated: 501,
                    sourceDevice: "android-a"
                )
            ],
            sourceDevice: "android-a",
            patchNumber: 2,
            fileTimestamp: 501
        )
        defer { try? FileManager.default.removeItem(at: newerArchive.archiveFileURL) }

        let newerReport = try applyService.applyPatchArchives(
            [newerArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(newerReport.appliedLogEntryCount, 1)
        XCTAssertEqual(newerReport.skippedLogEntryCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(modelContext.fetch(FetchDescriptor<LLMProviderConfig>()).first).displayName,
            "Remote provider"
        )
        let acceptedEntry = try XCTUnwrap(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings)
                .first(where: { $0.tableName == "LlmProviderConfig" })
        )
        XCTAssertEqual(acceptedEntry.lastUpdated, 501)
        XCTAssertEqual(acceptedEntry.sourceDevice, "android-a")
    }

    /**
     Verifies one provider tombstone reproduces Android's post-patch foreign-key cleanup.

     Removing the provider must prune its formally dependent model, model-bound prompt, and built-in
     override. Android's logical references must remain: usage and global default keep the deleted
     model UUID, and a prompt with a missing category but no model dependency survives. The accepted
     provider tombstone must also remain as the conflict watermark. Failure means iOS either retains
     formal orphans or invents stronger relationships than Android declares.
     */
    func testProviderTombstonePrunesFormalDependentsWhileLogicalReferencesSurvive() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "d2000000-0000-0000-0000-000000000001")!
        let modelID = UUID(uuidString: "d3000000-0000-0000-0000-000000000001")!
        let formalPromptID = UUID(uuidString: "d4000000-0000-0000-0000-000000000001")!
        let logicalPromptID = UUID(uuidString: "d4000000-0000-0000-0000-000000000002")!
        let usageID = UUID(uuidString: "d6000000-0000-0000-0000-000000000001")!
        let overrideID = UUID(uuidString: "d7000000-0000-0000-0000-000000000001")!
        let missingCategoryID = UUID(uuidString: "d5000000-0000-0000-0000-000000000099")!

        modelContext.insert(
            LLMProviderConfig(id: providerID, provider: .openAI, displayName: "Delete me")
        )
        modelContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: providerID,
                modelId: "deleted-model"
            )
        )
        modelContext.insert(
            AgentPrompt(
                id: formalPromptID,
                name: "Formal model prompt",
                promptTemplate: "Use model",
                configuredModelId: modelID
            )
        )
        modelContext.insert(
            AgentPrompt(
                id: logicalPromptID,
                name: "Logical category prompt",
                promptTemplate: "Keep category identity",
                categoryId: missingCategoryID
            )
        )
        let globalSettings = GlobalAISettings()
        globalSettings.defaultModelId = modelID
        modelContext.insert(globalSettings)
        let usage = LLMUsageRecord(id: usageID, configuredModelId: modelID, deviceId: "ios-device")
        usage.inputTokens = 42
        modelContext.insert(usage)
        modelContext.insert(BuiltInPromptOverride(id: overrideID, configuredModelId: modelID))
        try modelContext.save()

        let emptySnapshot = try makeEmptyAISettingsSnapshot()
        let deleteArchive = try makeAISettingsPatchArchive(
            snapshot: emptySnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: providerID,
                    type: .delete,
                    lastUpdated: 1_000,
                    sourceDevice: "android-device"
                )
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 1_000
        )
        defer { try? FileManager.default.removeItem(at: deleteArchive.archiveFileURL) }

        let report = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        ).applyPatchArchives(
            [deleteArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.providerCount, 0)
        XCTAssertEqual(report.configuredModelCount, 0)
        XCTAssertEqual(report.agentPromptCount, 1)
        XCTAssertEqual(report.globalSettingsCount, 1)
        XCTAssertEqual(report.usageRecordCount, 1)
        XCTAssertEqual(report.builtinOverrideCount, 0)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LLMProviderConfig>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>()).isEmpty)
        XCTAssertEqual(
            try modelContext.fetch(FetchDescriptor<AgentPrompt>()).map(\.id),
            [logicalPromptID]
        )
        XCTAssertEqual(
            try XCTUnwrap(modelContext.fetch(FetchDescriptor<AgentPrompt>()).first).categoryId,
            missingCategoryID
        )
        XCTAssertEqual(
            try XCTUnwrap(modelContext.fetch(FetchDescriptor<GlobalAISettings>()).first).defaultModelId,
            modelID
        )
        XCTAssertEqual(
            try XCTUnwrap(modelContext.fetch(FetchDescriptor<LLMUsageRecord>()).first).configuredModelId,
            modelID
        )
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BuiltInPromptOverride>()).isEmpty)

        let tombstone = try XCTUnwrap(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings)
                .first(where: { $0.tableName == "LlmProviderConfig" })
        )
        XCTAssertEqual(tombstone.type, .delete)
        XCTAssertEqual(tombstone.lastUpdated, 1_000)
    }

    /**
     Verifies Android metadata-only UPSERTs advance conflict state without requiring payload rows.

     Android retains `LogEntry` after formal-FK cleanup and can later publish that watermark without
     the deleted row. Replay must accept the metadata, leave the graph unchanged, and continue the
     patch batch. Failure means a normal Android sparse patch aborts iOS synchronization.
     */
    func testMetadataOnlyUpsertAdvancesWatermarkWithoutCreatingPayload() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let promptID = UUID(uuidString: "d4000000-0000-0000-0000-000000000010")!
        let archive = try makeAISettingsPatchArchive(
            snapshot: makeEmptyAISettingsSnapshot(),
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "AgentPrompt",
                    id: promptID,
                    type: .upsert,
                    lastUpdated: 1_100,
                    sourceDevice: "android-device"
                )
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 1_100
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        let report = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        ).applyPatchArchives(
            [archive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<AgentPrompt>()).isEmpty)
        let acceptedEntry = try XCTUnwrap(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings)
                .first(where: { $0.tableName == "AgentPrompt" })
        )
        XCTAssertEqual(acceptedEntry.type, .upsert)
        XCTAssertEqual(acceptedEntry.lastUpdated, 1_100)
    }

    /**
     Pins Android's table-local FK cleanup order when one patch reparents a model.

     Provider deletion runs before the model UPSERT, but Android does not inspect model FKs until
     the model table phase. The model can therefore move to a surviving provider before prompt FKs
     are checked, preserving its unchanged prompt. Failure means iOS prunes repairable child rows
     earlier than Android.
     */
    func testProviderDeletionAllowsLaterModelReparentingBeforePromptCleanup() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let oldProviderID = UUID(uuidString: "d2000000-0000-0000-0000-000000000020")!
        let newProviderID = UUID(uuidString: "d2000000-0000-0000-0000-000000000021")!
        let modelID = UUID(uuidString: "d3000000-0000-0000-0000-000000000020")!
        let promptID = UUID(uuidString: "d4000000-0000-0000-0000-000000000020")!
        modelContext.insert(
            LLMProviderConfig(id: oldProviderID, provider: .openAI, displayName: "Old")
        )
        modelContext.insert(
            LLMProviderConfig(id: newProviderID, provider: .anthropic, displayName: "New")
        )
        modelContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: oldProviderID,
                modelId: "reparented-model"
            )
        )
        modelContext.insert(
            AgentPrompt(
                id: promptID,
                name: "Keep me",
                promptTemplate: "Use the repaired model",
                configuredModelId: modelID
            )
        )
        try modelContext.save()

        let remoteContainer = try makeAISettingsSyncContainer()
        let remoteContext = ModelContext(remoteContainer)
        remoteContext.insert(
            LLMProviderConfig(id: newProviderID, provider: .anthropic, displayName: "New")
        )
        remoteContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: newProviderID,
                modelId: "reparented-model"
            )
        )
        try remoteContext.save()
        let remoteSnapshot = try makeCredentialFreeAISettingsSnapshotService().snapshotCurrentStateStrict(
            modelContext: remoteContext,
            settingsStore: SettingsStore(modelContext: remoteContext)
        )
        let archive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: oldProviderID,
                    type: .delete,
                    lastUpdated: 1_200,
                    sourceDevice: "android-device"
                ),
                aiSettingsLogEntry(
                    tableName: "LlmConfiguredModel",
                    id: modelID,
                    type: .upsert,
                    lastUpdated: 1_201,
                    sourceDevice: "android-device"
                ),
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 1_201
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        _ = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        ).applyPatchArchives(
            [archive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertNil(try modelContext.fetch(FetchDescriptor<LLMProviderConfig>())
            .first(where: { $0.id == oldProviderID }))
        XCTAssertEqual(try XCTUnwrap(modelContext.fetch(FetchDescriptor<LLMConfiguredModel>()).first)
            .providerConfigId, newProviderID)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<AgentPrompt>()).map(\.id), [promptID])
    }

    /**
     Ensures FK-cleanup metadata never becomes a newer synthetic local tombstone.

     The first patch removes a provider and carries a metadata-only model UPSERT, leaving Android's
     accepted watermark but no model row. A later unrelated global-setting edit must upload only
     that edit. Failure means iOS can erase a valid model recreated elsewhere after the cleanup.
     */
    func testForeignKeyCleanupDoesNotGenerateSyntheticDeletionOnNextUpload() async throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "d2000000-0000-0000-0000-000000000030")!
        let modelID = UUID(uuidString: "d3000000-0000-0000-0000-000000000030")!
        modelContext.insert(
            LLMProviderConfig(id: providerID, provider: .openAI, displayName: "Removed")
        )
        modelContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: providerID,
                modelId: "removed-model"
            )
        )
        try modelContext.save()

        let archive = try makeAISettingsPatchArchive(
            snapshot: makeEmptyAISettingsSnapshot(),
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: providerID,
                    type: .delete,
                    lastUpdated: 1_300,
                    sourceDevice: "android-device"
                ),
                aiSettingsLogEntry(
                    tableName: "LlmConfiguredModel",
                    id: modelID,
                    type: .upsert,
                    lastUpdated: 1_301,
                    sourceDevice: "android-device"
                ),
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 1_301
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }
        let snapshotService = makeCredentialFreeAISettingsSnapshotService()
        _ = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: snapshotService
        ).applyPatchArchives(
            [archive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>()).isEmpty)

        let aiStore = AISettingsStore(
            modelContext: modelContext,
            remoteSyncSnapshotService: snapshotService
        )
        let globalSettings = try aiStore.globalSettings()
        globalSettings.aiLanguage = "fi-FI"
        try aiStore.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(uploadMetadata: [.init(timestamp: 1_400)])
        let directoryURL = try makeAISettingsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let uploadService = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directoryURL,
            outboxDirectory: directoryURL.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 1_400 }
        )
        let optionalReport = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-ai_settings",
                deviceFolderID: "/org.andbible.ios-sync-ai_settings/ios-device",
                secretFileName: "device-known-ios-device-secret",
                phase: .ready
            ),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(optionalReport)

        XCTAssertEqual(
            report.tableReports.first(where: { $0.tableName == "LlmConfiguredModel" })?.deletedRowCount,
            0
        )
        XCTAssertEqual(
            report.tableReports.first(where: { $0.tableName == "GlobalAiSettings" })?.upsertedRowCount,
            1
        )
    }

    /**
     Proves a sparse child-row patch resolves formal parents from the existing local generation.

     Android patch databases include only changed rows, so an updated configured model can appear
     without its unchanged provider. Replay must merge first and evaluate foreign keys against the
     complete graph. A failure means valid Android sparse patches are incorrectly rejected as
     standalone restore snapshots.
     */
    func testSparseConfiguredModelUpdateUsesExistingLocalProvider() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "e2000000-0000-0000-0000-000000000001")!
        let modelID = UUID(uuidString: "e3000000-0000-0000-0000-000000000001")!
        modelContext.insert(
            LLMProviderConfig(id: providerID, provider: .anthropic, displayName: "Anthropic")
        )
        modelContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: providerID,
                modelId: "claude-before",
                orderNumber: 1
            )
        )
        try modelContext.save()

        let remoteContainer = try makeAISettingsSyncContainer()
        let remoteContext = ModelContext(remoteContainer)
        remoteContext.insert(
            LLMProviderConfig(id: providerID, provider: .anthropic, displayName: "Anthropic")
        )
        remoteContext.insert(
            LLMConfiguredModel(
                id: modelID,
                providerConfigId: providerID,
                modelId: "claude-after",
                orderNumber: 2,
                inputPricePerMillion: 3,
                outputPricePerMillion: 15
            )
        )
        try remoteContext.save()
        let remoteSnapshot = try makeCredentialFreeAISettingsSnapshotService().snapshotCurrentStateStrict(
            modelContext: remoteContext,
            settingsStore: SettingsStore(modelContext: remoteContext)
        )
        let archive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmConfiguredModel",
                    id: modelID,
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "android-device"
                )
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 2_000
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        let report = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        ).applyPatchArchives(
            [archive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.providerCount, 1)
        XCTAssertEqual(report.configuredModelCount, 1)
        let model = try XCTUnwrap(modelContext.fetch(FetchDescriptor<LLMConfiguredModel>()).first)
        XCTAssertEqual(model.providerConfigId, providerID)
        XCTAssertEqual(model.modelId, "claude-after")
        XCTAssertEqual(model.orderNumber, 2)
        XCTAssertEqual(model.inputPricePerMillion, 3)
        XCTAssertEqual(model.outputPricePerMillion, 15)
    }

    /**
     Pins SQLite's primary-identity behavior for Android's two composite unique indexes.

     Android patch replay uses `ON CONFLICT DO UPDATE` without assigning the primary `id` column.
     Incoming model and usage rows therefore update the rows already occupying their composite keys
     while retaining the local primary UUIDs. A failure means iOS changes stable identities and can
     disconnect references even though Android would preserve them.
     */
    func testCompositeUniqueConflictsPreserveExistingPrimaryIdentities() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "e4000000-0000-0000-0000-000000000001")!
        let localModelID = UUID(uuidString: "e5000000-0000-0000-0000-000000000001")!
        let remoteModelID = UUID(uuidString: "e5000000-0000-0000-0000-000000000002")!
        let localUsageID = UUID(uuidString: "e6000000-0000-0000-0000-000000000001")!
        let remoteUsageID = UUID(uuidString: "e6000000-0000-0000-0000-000000000002")!
        modelContext.insert(
            LLMProviderConfig(id: providerID, provider: .openAI, displayName: "OpenAI")
        )
        modelContext.insert(
            LLMConfiguredModel(
                id: localModelID,
                providerConfigId: providerID,
                modelId: "shared-model",
                orderNumber: 1
            )
        )
        let localUsage = LLMUsageRecord(
            id: localUsageID,
            configuredModelId: localModelID,
            deviceId: "shared-device"
        )
        localUsage.inputTokens = 10
        modelContext.insert(localUsage)
        try modelContext.save()

        let remoteContainer = try makeAISettingsSyncContainer()
        let remoteContext = ModelContext(remoteContainer)
        remoteContext.insert(
            LLMProviderConfig(id: providerID, provider: .openAI, displayName: "OpenAI")
        )
        remoteContext.insert(
            LLMConfiguredModel(
                id: remoteModelID,
                providerConfigId: providerID,
                modelId: "shared-model",
                orderNumber: 9,
                inputPricePerMillion: 2,
                outputPricePerMillion: 8
            )
        )
        let remoteUsage = LLMUsageRecord(
            id: remoteUsageID,
            configuredModelId: localModelID,
            deviceId: "shared-device"
        )
        remoteUsage.inputTokens = 99
        remoteUsage.outputTokens = 55
        remoteUsage.estimatedCostUSD = 1.5
        remoteContext.insert(remoteUsage)
        try remoteContext.save()

        let remoteSnapshot = try makeCredentialFreeAISettingsSnapshotService().snapshotCurrentStateStrict(
            modelContext: remoteContext,
            settingsStore: SettingsStore(modelContext: remoteContext)
        )
        let archive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmConfiguredModel",
                    id: remoteModelID,
                    type: .upsert,
                    lastUpdated: 3_000,
                    sourceDevice: "android-device"
                ),
                aiSettingsLogEntry(
                    tableName: "LlmUsageRecord",
                    id: remoteUsageID,
                    type: .upsert,
                    lastUpdated: 3_001,
                    sourceDevice: "android-device"
                ),
            ],
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: 3_001
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        _ = try RemoteSyncAISettingsPatchApplyService(
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        ).applyPatchArchives(
            [archive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let models = try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>())
        let usages = try modelContext.fetch(FetchDescriptor<LLMUsageRecord>())
        XCTAssertEqual(models.map(\.id), [localModelID])
        XCTAssertEqual(models.first?.orderNumber, 9)
        XCTAssertEqual(models.first?.inputPricePerMillion, 2)
        XCTAssertEqual(models.first?.outputPricePerMillion, 8)
        XCTAssertEqual(usages.map(\.id), [localUsageID])
        XCTAssertEqual(usages.first?.inputTokens, 99)
        XCTAssertEqual(usages.first?.outputTokens, 55)
        XCTAssertEqual(usages.first?.estimatedCostUSD, 1.5)
    }

    /**
     Verifies an already-uploaded generation remains durable when local acceptance is interrupted.

     The first call publishes immutable bytes and fails at the injected pre-commit checkpoint. The
     manifest and archive must remain available for restart. Resumption must reconcile the same remote
     object, accept it without a second upload, and clear the outbox. Failure means transport success
     can lose local mutation state or duplicate Android patch files after a crash.
     */
    func testInterruptedLocalAcceptanceResumesDurableOutboxWithoutReupload() async throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = makeCredentialFreeAISettingsSnapshotService()
        try AISettingsStore(
            modelContext: modelContext,
            remoteSyncSnapshotService: snapshotService
        ).insertProvider(
            LLMProviderConfig(
                id: UUID(uuidString: "f2000000-0000-0000-0000-000000000001")!,
                provider: .openAI,
                displayName: "OpenAI"
            )
        )

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 3_000)]
        )
        let directoryURL = try makeAISettingsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let service = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directoryURL,
            outboxDirectory: directoryURL.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 2_000 }
        )
        let bootstrapState = RemoteSyncBootstrapState(
            syncFolderID: "/org.andbible.ios-sync-ai_settings",
            deviceFolderID: "/org.andbible.ios-sync-ai_settings/ios-device",
            secretFileName: "device-known-ios-device-secret",
            phase: .ready
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                acceptanceCheckpoint: {
                    throw SimulatedAISettingsAcceptanceError.interruptedBeforeAcceptance
                }
            )
            XCTFail("Expected local acceptance interruption")
        } catch {
            XCTAssertEqual(
                error as? SimulatedAISettingsAcceptanceError,
                .interruptedBeforeAcceptance
            )
        }

        XCTAssertNotNil(
            settingsStore.getString(RemoteSyncAISettingsPatchUploadService.pendingUploadKey)
        )
        let uploadsBeforeResume = await adapter.uploads()
        XCTAssertEqual(uploadsBeforeResume.count, 1)

        let resumedReport = try await service.resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(resumedReport)

        XCTAssertEqual(report.patchNumber, 1)
        XCTAssertEqual(report.logEntryCount, 1)
        XCTAssertEqual(
            report.tableReports.first(where: { $0.tableName == "LlmProviderConfig" })?.upsertedRowCount,
            1
        )
        XCTAssertNil(settingsStore.getString(RemoteSyncAISettingsPatchUploadService.pendingUploadKey))
        let uploadsAfterResume = await adapter.uploads()
        XCTAssertEqual(uploadsAfterResume.count, 1)
    }

    /**
     Verifies replay cannot absorb a local mutation by refreshing its accepted fingerprint baseline.

     The fixture records a mutation-time journal entry, then simulates inbound replay refreshing the
     baseline to that same live row before outbound publication. The pending marker must still force an
     UPSERT with its original timestamp and must clear only after remote and local acceptance succeed.
     */
    func testPendingMutationUploadsAfterReplayRefreshesMatchingBaseline() async throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let providerID = UUID(uuidString: "f2000000-0000-0000-0000-000000000002")!
        let provider = LLMProviderConfig(
            id: providerID,
            provider: .openAI,
            displayName: "Before edit"
        )
        modelContext.insert(provider)
        try modelContext.save()
        let snapshotService = RemoteSyncAISettingsSnapshotService(credentialForProvider: { _ in nil })
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        provider.displayName = "Edited during synchronization"
        try AISettingsStore(
            modelContext: modelContext,
            remoteSyncSnapshotService: snapshotService
        ).save()
        let journalService = RemoteSyncMutationJournalService(
            aiSettingsSnapshotService: snapshotService
        )
        let pendingBeforeReplay = try journalService.pendingMutations(
            for: .aiSettings,
            settingsStore: settingsStore
        )
        let pendingEntry = try XCTUnwrap(pendingBeforeReplay.values.first?.entry)
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let adapter = RemoteSyncDurableOutboxTestAdapter(uploadMetadata: [.init(timestamp: 4_000)])
        let directoryURL = try makeAISettingsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let service = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directoryURL,
            outboxDirectory: directoryURL.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 3_000 }
        )
        let optionalReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-ai_settings",
                deviceFolderID: "/org.andbible.ios-sync-ai_settings/ios-device",
                secretFileName: "device-known-ios-device-secret",
                phase: .ready
            ),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(optionalReport)

        XCTAssertEqual(report.logEntryCount, 1)
        XCTAssertEqual(
            report.tableReports.first(where: { $0.tableName == "LlmProviderConfig" })?.upsertedRowCount,
            1
        )
        XCTAssertEqual(
            try RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings)
                .first(where: { $0.tableName == "LlmProviderConfig" }),
            pendingEntry
        )
        XCTAssertTrue(
            try journalService.pendingMutations(for: .aiSettings, settingsStore: settingsStore).isEmpty
        )
    }

    /**
     Verifies initial-backup acceptance clears represented markers but preserves edits made in flight.

     The initial generation captures the first provider state. A second local save replaces the marker
     before acceptance; cleanup against the older generation must retain it. Cleanup against the exact
     current generation then removes it, proving restart/reset metadata cannot remain perpetually dirty.
     */
    func testInitialBaselineMarkerCleanupPreservesOnlyLaterMutations() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncAISettingsSnapshotService(credentialForProvider: { _ in nil })
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let provider = LLMProviderConfig(
            id: UUID(uuidString: "f2000000-0000-0000-0000-000000000003")!,
            provider: .openAI,
            displayName: "Initial archive value"
        )
        let aiStore = AISettingsStore(
            modelContext: modelContext,
            remoteSyncSnapshotService: snapshotService
        )
        try aiStore.insertProvider(provider)
        let initialSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        provider.displayName = "Edited during upload"
        try aiStore.save()
        let journalService = RemoteSyncMutationJournalService(
            aiSettingsSnapshotService: snapshotService
        )
        try journalService.clearPendingMutationsAcceptedByBaseline(
            initialSnapshot.fingerprintsByKey,
            for: .aiSettings,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(
            try journalService.pendingMutations(for: .aiSettings, settingsStore: settingsStore).count,
            1
        )

        let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try journalService.clearPendingMutationsAcceptedByBaseline(
            currentSnapshot.fingerprintsByKey,
            for: .aiSettings,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(
            try journalService.pendingMutations(for: .aiSettings, settingsStore: settingsStore).isEmpty
        )
    }

    /**
     Verifies the public upload entry point rejects non-v23 requests before remote discovery.

     The valid ready bootstrap state isolates schema validation from missing-destination errors. A
     failure means callers can receive an internal writer failure or perform remote I/O for a schema
     Android cannot consume.
     */
    func testUploadRejectsUnsupportedSchemaWithPublicError() async throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: makeCredentialFreeAISettingsSnapshotService()
        )
        let bootstrapState = RemoteSyncBootstrapState(
            syncFolderID: "/org.andbible.ios-sync-ai_settings",
            deviceFolderID: "/org.andbible.ios-sync-ai_settings/ios-device",
            secretFileName: "device-known-ios-device-secret",
            phase: .ready
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: 22
            )
            XCTFail("Expected an unsupported AI settings schema error")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncAISettingsPatchUploadError,
                .unsupportedSchemaVersion(22)
            )
        }
        let events = await adapter.eventsSnapshot()
        XCTAssertTrue(events.isEmpty)
    }

    /**
     Proves the active AI Settings toggle reaches real initial upload and adoption through lifecycle sync.

     Device A enables only `AI_SETTINGS`; the lifecycle runner must discover no remote folder,
     create it, and publish a complete Android v23 `initial.sqlite3.gz`. Device B enables the same
     category, receives the remote-adoption decision, and resumes through the lifecycle continuation
     to restore all seven synchronized tables. Device B begins with its own credential and raw log,
     which must survive the destructive initial replacement. Fixed adapter queues and clocks make
     every bootstrap, upload, and download boundary deterministic. A failure means the visible
     active toggle is not connected to the category's production bootstrap path. Temporary staging
     and durable-outbox directories are removed at completion.
     */
    func testLifecycleCreatesAndAdoptsAISettingsInitialBackupWithoutLocalSecretLoss() async throws {
        let syncFolderID = "/org.andbible.ios-sync-ai_settings"
        let sourceDeviceFolderID = "\(syncFolderID)/ios-source"
        let destinationDeviceFolderID = "\(syncFolderID)/ios-destination"
        let sourceMarker = "device-known-ios-source-secret"
        let destinationMarker = "device-known-ios-destination-secret"
        let sourceDirectory = try makeAISettingsTemporaryDirectory()
        let destinationDirectory = try makeAISettingsTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        let sourceContainer = try makeAISettingsSyncContainer()
        let sourceConfigurationContext = ModelContext(sourceContainer)
        let sourceSettingsStore = SettingsStore(modelContext: sourceConfigurationContext)
        let sourceSecrets = InMemorySecretStore()
        let sourceRemoteSettings = RemoteSyncSettingsStore(
            settingsStore: sourceSettingsStore,
            secretStore: sourceSecrets
        )
        sourceRemoteSettings.selectedBackend = .nextCloud
        try sourceRemoteSettings.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "source",
                folderPath: nil
            ),
            password: "source-webdav-password"
        )
        sourceRemoteSettings.setSyncEnabled(true, for: .aiSettings)
        let fixtureIDs = try insertCompleteAISettingsFixture(into: sourceConfigurationContext)
        let sourceCredentials = AICredentialStore(secretStore: sourceSecrets)
        try sourceCredentials.setCredential("source-provider-secret", for: fixtureIDs.provider)
        let sourceSnapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { sourceCredentials.credential(for: $0) }
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setMakeKnownResponse(sourceMarker)
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: syncFolderID,
                name: "org.andbible.ios-sync-ai_settings",
                size: 0,
                timestamp: 1_000,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 1_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 3_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 1_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])

        let sourceCoordinator = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-source",
            initialBackupRestoreService: RemoteSyncInitialBackupRestoreService(
                aiSettingsSnapshotService: sourceSnapshotService
            ),
            initialBackupUploadService: RemoteSyncInitialBackupUploadService(
                adapter: adapter,
                deviceIdentifier: "ios-source",
                aiSettingsSnapshotService: sourceSnapshotService,
                temporaryDirectory: sourceDirectory,
                retryDirectory: sourceDirectory.appendingPathComponent("initial-outbox", isDirectory: true),
                nowProvider: { 2_000 }
            ),
            aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService(
                snapshotService: sourceSnapshotService,
                temporaryDirectory: sourceDirectory
            ),
            aiSettingsPatchUploadService: RemoteSyncAISettingsPatchUploadService(
                adapter: adapter,
                snapshotService: sourceSnapshotService,
                temporaryDirectory: sourceDirectory,
                outboxDirectory: sourceDirectory.appendingPathComponent("patch-outbox", isDirectory: true),
                nowProvider: { 2_000 }
            ),
            temporaryDirectory: sourceDirectory,
            nowProvider: { 2_000 }
        )
        let sourceLifecycle = RemoteSyncLifecycleService(
            modelContainer: sourceContainer,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in sourceCoordinator },
            remoteSettingsStoreFactory: {
                RemoteSyncSettingsStore(settingsStore: $0, secretStore: sourceSecrets)
            },
            nowProvider: { 2_000 }
        )

        var sourceReport: RemoteSyncCategorySynchronizationReport?
        sourceLifecycle.onCategorySynchronized = { sourceReport = $0 }
        let didCreateSource = await sourceLifecycle.synchronizeIfNeeded(force: true)
        XCTAssertTrue(didCreateSource)
        XCTAssertEqual(sourceReport?.category, .aiSettings)
        XCTAssertNil(sourceReport?.patchUploadReport)
        let sourceUploads = await adapter.uploadedFilesSnapshot()
        let initialUpload = try XCTUnwrap(sourceUploads.first)
        XCTAssertEqual(sourceUploads.count, 1)
        XCTAssertEqual(initialUpload.name, "initial.sqlite3.gz")

        let destinationContainer = try makeAISettingsSyncContainer()
        let destinationConfigurationContext = ModelContext(destinationContainer)
        let destinationSettingsStore = SettingsStore(modelContext: destinationConfigurationContext)
        let destinationSecrets = InMemorySecretStore()
        let destinationRemoteSettings = RemoteSyncSettingsStore(
            settingsStore: destinationSettingsStore,
            secretStore: destinationSecrets
        )
        destinationRemoteSettings.selectedBackend = .nextCloud
        try destinationRemoteSettings.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "destination",
                folderPath: nil
            ),
            password: "destination-webdav-password"
        )
        destinationRemoteSettings.setSyncEnabled(true, for: .aiSettings)
        let destinationCredentials = AICredentialStore(secretStore: destinationSecrets)
        try destinationCredentials.setCredential("destination-provider-secret", for: fixtureIDs.provider)
        let destinationSnapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { destinationCredentials.credential(for: $0) }
        )
        let destinationRawLog = LLMRawLogRecord(
            id: UUID(uuidString: "f8000000-0000-0000-0000-000000000020")!,
            promptName: "Destination lifecycle log",
            modelName: "local-model",
            providerType: "CUSTOM",
            timestampMilliseconds: 4_000,
            logData: Data("destination-lifecycle-raw-log".utf8)
        )
        destinationConfigurationContext.insert(destinationRawLog)
        try destinationConfigurationContext.save()

        let syncFolder = RemoteSyncFile(
            id: syncFolderID,
            name: "org.andbible.ios-sync-ai_settings",
            size: 0,
            timestamp: 1_000,
            parentID: "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let initialFile = RemoteSyncFile(
            id: "\(syncFolderID)/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialUpload.data.count),
            timestamp: 3_000,
            parentID: syncFolderID,
            mimeType: initialUpload.contentType
        )
        await adapter.setDownloadData(initialUpload.data, forID: initialFile.id)
        await adapter.enqueueListFilesResult([syncFolder])
        await adapter.setMakeKnownResponse(destinationMarker)
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: destinationDeviceFolderID,
                name: "ios-destination",
                size: 0,
                timestamp: 4_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 1_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
            RemoteSyncFile(
                id: destinationDeviceFolderID,
                name: "ios-destination",
                size: 0,
                timestamp: 4_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
        ])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueListFilesResult([])

        let destinationCoordinator = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-destination",
            initialBackupRestoreService: RemoteSyncInitialBackupRestoreService(
                aiSettingsSnapshotService: destinationSnapshotService
            ),
            initialBackupUploadService: RemoteSyncInitialBackupUploadService(
                adapter: adapter,
                deviceIdentifier: "ios-destination",
                aiSettingsSnapshotService: destinationSnapshotService,
                temporaryDirectory: destinationDirectory,
                retryDirectory: destinationDirectory.appendingPathComponent("initial-outbox", isDirectory: true),
                nowProvider: { 5_000 }
            ),
            aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService(
                snapshotService: destinationSnapshotService,
                temporaryDirectory: destinationDirectory
            ),
            aiSettingsPatchUploadService: RemoteSyncAISettingsPatchUploadService(
                adapter: adapter,
                snapshotService: destinationSnapshotService,
                temporaryDirectory: destinationDirectory,
                outboxDirectory: destinationDirectory.appendingPathComponent("patch-outbox", isDirectory: true),
                nowProvider: { 5_000 }
            ),
            temporaryDirectory: destinationDirectory,
            nowProvider: { 5_000 }
        )
        let destinationLifecycle = RemoteSyncLifecycleService(
            modelContainer: destinationContainer,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in destinationCoordinator },
            remoteSettingsStoreFactory: {
                RemoteSyncSettingsStore(settingsStore: $0, secretStore: destinationSecrets)
            },
            nowProvider: { 5_000 }
        )

        var adoptionCandidate: RemoteSyncBootstrapCandidate?
        destinationLifecycle.onInteractionRequired = { category, outcome in
            guard category == .aiSettings,
                  case .requiresRemoteAdoption(let candidate) = outcome else {
                return
            }
            adoptionCandidate = candidate
        }
        let didSynchronizeBeforeAdoption = await destinationLifecycle.synchronizeIfNeeded(force: true)
        XCTAssertFalse(didSynchronizeBeforeAdoption)
        XCTAssertEqual(adoptionCandidate?.remoteFolderID, syncFolderID)
        let didAdoptDestination = await destinationLifecycle.adoptRemoteFolderAndSynchronize(
            try XCTUnwrap(adoptionCandidate)
        )
        XCTAssertTrue(didAdoptDestination)

        let destinationVerificationContext = ModelContext(destinationContainer)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<LLMProviderConfig>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<LLMConfiguredModel>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<AgentPrompt>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<GlobalAISettings>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<LLMUsageRecord>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<PromptCategory>()).count, 1)
        XCTAssertEqual(try destinationVerificationContext.fetch(FetchDescriptor<BuiltInPromptOverride>()).count, 1)
        XCTAssertEqual(
            try destinationVerificationContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [destinationRawLog.id]
        )
        XCTAssertEqual(
            destinationCredentials.credential(for: fixtureIDs.provider),
            "destination-provider-secret"
        )
    }

    /**
     Proves two ready devices converge through the production AI settings synchronization route.

     Device A starts from an accepted empty baseline, creates one row in each of Android's seven
     `AI_SETTINGS` tables, and publishes one sparse v23 patch through
     `RemoteSyncSynchronizationService`. Device B starts from the same empty synchronized baseline
     plus a local credential and raw log, then discovers, downloads, and replays that exact archive
     through a second coordinator instance. Device A then updates its provider and deletes its
     prompt; a second pair of coordinator passes must publish and replay only those changes. The
     destination then synchronizes once more without local edits and must neither upload an echo nor
     rediscover accepted patches. Fixed clocks and queued adapter responses make upload-before-list
     ordering deterministic. A failure means the category can pass isolated writer/replay tests while
     remaining disconnected, destructive, or self-amplifying in repeated top-level sync. Temporary
     outbox and staging directories are removed when the test completes.
     */
    func testSynchronizationCoordinatorConvergesAISettingsAcrossTwoDevicesWithoutLocalSecretLoss() async throws {
        let sourceContainer = try makeAISettingsSyncContainer()
        let sourceContext = ModelContext(sourceContainer)
        let sourceSettingsStore = SettingsStore(modelContext: sourceContext)
        let sourceSecrets = InMemorySecretStore()
        let sourceCredentials = AICredentialStore(secretStore: sourceSecrets)
        let sourceSnapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { sourceCredentials.credential(for: $0) }
        )
        try sourceSnapshotService.refreshBaselineFingerprintsStrict(
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        let fixtureIDs = try insertCompleteAISettingsFixture(into: sourceContext)
        try sourceCredentials.setCredential("source-device-secret", for: fixtureIDs.provider)

        let destinationContainer = try makeAISettingsSyncContainer()
        let destinationContext = ModelContext(destinationContainer)
        let destinationSettingsStore = SettingsStore(modelContext: destinationContext)
        let destinationSecrets = InMemorySecretStore()
        let destinationCredentials = AICredentialStore(secretStore: destinationSecrets)
        let destinationSnapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { destinationCredentials.credential(for: $0) }
        )
        try destinationSnapshotService.refreshBaselineFingerprintsStrict(
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        try destinationCredentials.setCredential("destination-device-secret", for: fixtureIDs.provider)
        let destinationRawLog = LLMRawLogRecord(
            id: UUID(uuidString: "f8000000-0000-0000-0000-000000000010")!,
            promptName: "Destination-only run",
            modelName: "local-model",
            providerType: "CUSTOM",
            timestampMilliseconds: 8_000,
            logData: Data("destination-only-raw-log".utf8)
        )
        destinationContext.insert(destinationRawLog)
        try destinationContext.save()

        let syncFolderID = "/org.andbible.ios-sync-ai_settings"
        let sourceDeviceFolderID = "\(syncFolderID)/ios-source"
        let destinationDeviceFolderID = "\(syncFolderID)/ios-destination"
        let sourceMarker = "device-known-ios-source-secret"
        let destinationMarker = "device-known-ios-destination-secret"
        RemoteSyncStateStore(settingsStore: sourceSettingsStore).setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: sourceDeviceFolderID,
                secretFileName: sourceMarker,
                phase: .ready
            ),
            for: .aiSettings
        )
        RemoteSyncStateStore(settingsStore: destinationSettingsStore).setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: destinationDeviceFolderID,
                secretFileName: destinationMarker,
                phase: .ready
            ),
            for: .aiSettings
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: sourceMarker
        )
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: destinationMarker
        )
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(sourceDeviceFolderID)/1.23.sqlite3.gz",
                name: "1.23.sqlite3.gz",
                size: 0,
                timestamp: 6_000,
                parentID: sourceDeviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        await adapter.enqueueListFilesResult([])

        let sourceDirectory = try makeAISettingsTemporaryDirectory()
        let destinationDirectory = try makeAISettingsTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let sourcePatchUploadService = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: sourceSnapshotService,
            temporaryDirectory: sourceDirectory,
            outboxDirectory: sourceDirectory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 5_000 }
        )
        let sourceService = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-source",
            aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService(
                snapshotService: sourceSnapshotService,
                temporaryDirectory: sourceDirectory
            ),
            aiSettingsPatchUploadService: sourcePatchUploadService,
            temporaryDirectory: sourceDirectory,
            nowProvider: { 5_000 }
        )

        let sourceOutcome = try await sourceService.synchronize(
            .aiSettings,
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        guard case .synchronized(let sourceReport) = sourceOutcome,
              case .aiSettings(let uploadReport)? = sourceReport.patchUploadReport else {
            return XCTFail("Expected device A to publish one AI settings patch")
        }
        XCTAssertEqual(sourceReport.category, .aiSettings)
        XCTAssertEqual(sourceReport.discoveredPatchCount, 0)
        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.logEntryCount, 7)
        XCTAssertEqual(uploadReport.tableReports.map(\.upsertedRowCount), Array(repeating: 1, count: 7))

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedPatch = try XCTUnwrap(uploadedFiles.first)
        XCTAssertEqual(uploadedFiles.count, 1)
        XCTAssertEqual(uploadedPatch.name, "1.23.sqlite3.gz")
        let patchFile = RemoteSyncFile(
            id: "\(sourceDeviceFolderID)/\(uploadedPatch.name)",
            name: uploadedPatch.name,
            size: Int64(uploadedPatch.data.count),
            timestamp: 6_000,
            parentID: sourceDeviceFolderID,
            mimeType: uploadedPatch.contentType
        )
        await adapter.setDownloadData(uploadedPatch.data, forID: patchFile.id)
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 5_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([patchFile])

        let destinationPatchUploadService = RemoteSyncAISettingsPatchUploadService(
            adapter: adapter,
            snapshotService: destinationSnapshotService,
            temporaryDirectory: destinationDirectory,
            outboxDirectory: destinationDirectory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 7_000 }
        )
        let destinationService = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-destination",
            aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService(
                snapshotService: destinationSnapshotService,
                temporaryDirectory: destinationDirectory
            ),
            aiSettingsPatchUploadService: destinationPatchUploadService,
            temporaryDirectory: destinationDirectory,
            nowProvider: { 7_000 }
        )

        let destinationOutcome = try await destinationService.synchronize(
            .aiSettings,
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        guard case .synchronized(let destinationReport) = destinationOutcome,
              case .aiSettings(let replayReport)? = destinationReport.patchReplayReport else {
            return XCTFail("Expected device B to replay device A's AI settings patch")
        }
        XCTAssertEqual(destinationReport.category, .aiSettings)
        XCTAssertEqual(destinationReport.discoveredPatchCount, 1)
        XCTAssertNil(destinationReport.patchUploadReport)
        XCTAssertEqual(replayReport.appliedPatchCount, 1)
        XCTAssertEqual(replayReport.appliedLogEntryCount, 7)
        XCTAssertEqual(replayReport.skippedLogEntryCount, 0)
        XCTAssertEqual(replayReport.providerCount, 1)
        XCTAssertEqual(replayReport.configuredModelCount, 1)
        XCTAssertEqual(replayReport.agentPromptCount, 1)
        XCTAssertEqual(replayReport.globalSettingsCount, 1)
        XCTAssertEqual(replayReport.usageRecordCount, 1)
        XCTAssertEqual(replayReport.promptCategoryCount, 1)
        XCTAssertEqual(replayReport.builtinOverrideCount, 1)

        let sourceSnapshot = try sourceSnapshotService.snapshotCurrentStateStrict(
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        let destinationSnapshot = try destinationSnapshotService.snapshotCurrentStateStrict(
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        XCTAssertEqual(destinationSnapshot, sourceSnapshot)
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [destinationRawLog.id]
        )
        XCTAssertEqual(
            destinationCredentials.credential(for: fixtureIDs.provider),
            "destination-device-secret"
        )

        let sourceProvider = try XCTUnwrap(
            try sourceContext.fetch(FetchDescriptor<LLMProviderConfig>()).first
        )
        let sourcePrompt = try XCTUnwrap(
            try sourceContext.fetch(FetchDescriptor<AgentPrompt>()).first
        )
        sourceProvider.displayName = "Updated on device A"
        try AISettingsStore(
            modelContext: sourceContext,
            remoteSyncSnapshotService: sourceSnapshotService
        ).deletePrompt(sourcePrompt)

        await adapter.enqueueListFilesResult([patchFile])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(sourceDeviceFolderID)/2.23.sqlite3.gz",
                name: "2.23.sqlite3.gz",
                size: 0,
                timestamp: 9_000,
                parentID: sourceDeviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        await adapter.enqueueListFilesResult([])

        let secondSourceOutcome = try await sourceService.synchronize(
            .aiSettings,
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        guard case .synchronized(let secondSourceReport) = secondSourceOutcome,
              case .aiSettings(let secondUploadReport)? = secondSourceReport.patchUploadReport else {
            return XCTFail("Expected device A to publish its update and tombstone")
        }
        XCTAssertEqual(secondUploadReport.patchNumber, 2)
        XCTAssertEqual(secondUploadReport.logEntryCount, 2)
        XCTAssertEqual(
            secondUploadReport.tableReports.first(where: {
                $0.tableName == "LlmProviderConfig"
            })?.upsertedRowCount,
            1
        )
        XCTAssertEqual(
            secondUploadReport.tableReports.first(where: {
                $0.tableName == "AgentPrompt"
            })?.deletedRowCount,
            1
        )

        let allUploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(allUploadedFiles.count, 2)
        let uploadedSecondPatch = allUploadedFiles[1]
        let secondPatchFile = RemoteSyncFile(
            id: "\(sourceDeviceFolderID)/\(uploadedSecondPatch.name)",
            name: uploadedSecondPatch.name,
            size: Int64(uploadedSecondPatch.data.count),
            timestamp: 9_000,
            parentID: sourceDeviceFolderID,
            mimeType: uploadedSecondPatch.contentType
        )
        await adapter.setDownloadData(uploadedSecondPatch.data, forID: secondPatchFile.id)
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 5_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([patchFile, secondPatchFile])

        let secondDestinationOutcome = try await destinationService.synchronize(
            .aiSettings,
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        guard case .synchronized(let secondDestinationReport) = secondDestinationOutcome,
              case .aiSettings(let secondReplayReport)? = secondDestinationReport.patchReplayReport else {
            return XCTFail("Expected device B to replay device A's second patch")
        }
        XCTAssertEqual(secondDestinationReport.discoveredPatchCount, 1)
        XCTAssertNil(secondDestinationReport.patchUploadReport)
        XCTAssertEqual(secondReplayReport.appliedPatchCount, 1)
        XCTAssertEqual(secondReplayReport.appliedLogEntryCount, 2)
        XCTAssertEqual(secondReplayReport.skippedLogEntryCount, 0)
        XCTAssertEqual(secondReplayReport.agentPromptCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(destinationContext.fetch(FetchDescriptor<LLMProviderConfig>()).first)
                .displayName,
            "Updated on device A"
        )
        XCTAssertTrue(try destinationContext.fetch(FetchDescriptor<AgentPrompt>()).isEmpty)

        let updatedSourceSnapshot = try sourceSnapshotService.snapshotCurrentStateStrict(
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore
        )
        let updatedDestinationSnapshot = try destinationSnapshotService.snapshotCurrentStateStrict(
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        XCTAssertEqual(updatedDestinationSnapshot, updatedSourceSnapshot)
        XCTAssertEqual(
            try destinationContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [destinationRawLog.id]
        )
        XCTAssertEqual(
            destinationCredentials.credential(for: fixtureIDs.provider),
            "destination-device-secret"
        )

        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: sourceDeviceFolderID,
                name: "ios-source",
                size: 0,
                timestamp: 5_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([patchFile, secondPatchFile])

        let settledDestinationOutcome = try await destinationService.synchronize(
            .aiSettings,
            modelContext: destinationContext,
            settingsStore: destinationSettingsStore
        )
        guard case .synchronized(let settledDestinationReport) = settledDestinationOutcome else {
            return XCTFail("Expected device B's settled synchronization to complete")
        }
        XCTAssertEqual(settledDestinationReport.discoveredPatchCount, 0)
        XCTAssertNil(settledDestinationReport.patchReplayReport)
        XCTAssertNil(settledDestinationReport.patchUploadReport)
        let settledUploads = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(settledUploads.count, 2)
    }

    /**
     Verifies cancellation at the final replay publication boundary rolls back every local mutation.

     The local generation contains a complete synchronized graph, accepted fingerprints, conflict
     metadata, an applied-patch status, a credential, and a raw log. A valid newer provider patch is
     fully decoded and staged before the injected second checkpoint throws `CancellationError` from
     inside the atomic publication transaction. The graph and all sync metadata must equal their
     pre-replay values, while device-local credential and raw-log state must remain untouched. A
     failure means cancellation can expose a mixed generation that Android would never publish.
     */
    func testPatchReplayCancellationBeforePublishRollsBackGraphMetadataAndLocalState() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let fixtureIDs = try insertCompleteAISettingsFixture(into: modelContext)
        let credentialStore = AICredentialStore(secretStore: InMemorySecretStore())
        try credentialStore.setCredential("destination-only-secret", for: fixtureIDs.provider)

        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { credentialStore.credential(for: $0) }
        )
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let localLogEntry = aiSettingsLogEntry(
            tableName: "LlmProviderConfig",
            id: fixtureIDs.provider,
            type: .upsert,
            lastUpdated: 1_000,
            sourceDevice: "ios-local"
        )
        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [localLogEntry],
            for: .aiSettings
        )
        let localPatchStatus = RemoteSyncPatchStatus(
            sourceDevice: "earlier-android",
            patchNumber: 1,
            sizeBytes: 321,
            appliedDate: 1_500
        )
        RemoteSyncPatchStatusStore(settingsStore: settingsStore).addStatus(
            localPatchStatus,
            for: .aiSettings
        )

        let remoteSnapshot = try makeProviderSnapshot(
            id: fixtureIDs.provider,
            displayName: "Remote provider value"
        )
        let archive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: fixtureIDs.provider,
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "android-device"
                )
            ],
            sourceDevice: "android-device",
            patchNumber: 2,
            fileTimestamp: 2_000
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        let graphBeforeReplay = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let baselineBeforeReplay = settingsStore.getString(
            RemoteSyncAISettingsSnapshotService.acceptedBaselineKey
        )
        let logsBeforeReplay = try RemoteSyncLogEntryStore(settingsStore: settingsStore)
            .entriesStrict(for: .aiSettings)
        let statusesBeforeReplay = try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            .statusesStrict(for: .aiSettings)
        var checkpointCount = 0

        XCTAssertThrowsError(
            try RemoteSyncAISettingsPatchApplyService(
                snapshotService: snapshotService
            ).applyPatchArchives(
                [archive],
                modelContext: modelContext,
                settingsStore: settingsStore,
                publishCheckpoint: {
                    checkpointCount += 1
                    if checkpointCount == 2 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(checkpointCount, 2)
        XCTAssertEqual(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            ),
            graphBeforeReplay
        )
        XCTAssertEqual(
            settingsStore.getString(RemoteSyncAISettingsSnapshotService.acceptedBaselineKey),
            baselineBeforeReplay
        )
        XCTAssertEqual(
            try RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings),
            logsBeforeReplay
        )
        XCTAssertEqual(
            try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statusesStrict(for: .aiSettings),
            statusesBeforeReplay
        )
        XCTAssertEqual(
            try modelContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [fixtureIDs.rawLog]
        )
        XCTAssertEqual(
            credentialStore.credential(for: fixtureIDs.provider),
            "destination-only-secret"
        )
    }

    /**
     Verifies a malformed later archive prevents publication of every earlier patch in the batch.

     The first archive is a valid newer provider UPSERT and the second has valid remote metadata but
     malformed gzip bytes. Replay must throw the precise bounded-file error before its one atomic
     publication, leaving the graph, accepted baseline, conflict log, patch statuses, credential,
     and raw log byte-for-byte equivalent to the pre-replay generation. A failure means one corrupt
     device stream can partially commit preceding Android patches.
     */
    func testCorruptSecondPatchRollsBackEntireAISettingsReplayBatch() throws {
        let container = try makeAISettingsSyncContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let fixtureIDs = try insertCompleteAISettingsFixture(into: modelContext)
        let credentialStore = AICredentialStore(secretStore: InMemorySecretStore())
        try credentialStore.setCredential("destination-only-secret", for: fixtureIDs.provider)

        let snapshotService = RemoteSyncAISettingsSnapshotService(
            credentialForProvider: { credentialStore.credential(for: $0) }
        )
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let localLogEntry = aiSettingsLogEntry(
            tableName: "LlmProviderConfig",
            id: fixtureIDs.provider,
            type: .upsert,
            lastUpdated: 1_000,
            sourceDevice: "ios-local"
        )
        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [localLogEntry],
            for: .aiSettings
        )
        let localPatchStatus = RemoteSyncPatchStatus(
            sourceDevice: "earlier-android",
            patchNumber: 1,
            sizeBytes: 321,
            appliedDate: 1_500
        )
        RemoteSyncPatchStatusStore(settingsStore: settingsStore).addStatus(
            localPatchStatus,
            for: .aiSettings
        )

        let remoteSnapshot = try makeProviderSnapshot(
            id: fixtureIDs.provider,
            displayName: "Remote provider value"
        )
        let validArchive = try makeAISettingsPatchArchive(
            snapshot: remoteSnapshot,
            logEntries: [
                aiSettingsLogEntry(
                    tableName: "LlmProviderConfig",
                    id: fixtureIDs.provider,
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "android-device"
                )
            ],
            sourceDevice: "android-device",
            patchNumber: 2,
            fileTimestamp: 2_000
        )
        let malformedArchiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-ai-settings-malformed-\(UUID().uuidString).sqlite3.gz")
        let malformedArchiveData = Data(repeating: 0x7f, count: 18)
        try malformedArchiveData.write(to: malformedArchiveURL, options: .atomic)
        let malformedArchive = RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: "second-android-device",
                patchNumber: 1,
                schemaVersion: RemoteSyncCategory.aiSettings.currentSchemaVersion,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-ai_settings/second-android-device/1.23.sqlite3.gz",
                    name: "1.23.sqlite3.gz",
                    size: Int64(malformedArchiveData.count),
                    timestamp: 2_500,
                    parentID: "/org.andbible.ios-sync-ai_settings/second-android-device",
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                )
            ),
            archiveFileURL: malformedArchiveURL
        )
        defer {
            try? FileManager.default.removeItem(at: validArchive.archiveFileURL)
            try? FileManager.default.removeItem(at: malformedArchiveURL)
        }

        let graphBeforeReplay = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let baselineBeforeReplay = settingsStore.getString(
            RemoteSyncAISettingsSnapshotService.acceptedBaselineKey
        )
        let logsBeforeReplay = try RemoteSyncLogEntryStore(settingsStore: settingsStore)
            .entriesStrict(for: .aiSettings)
        let statusesBeforeReplay = try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            .statusesStrict(for: .aiSettings)

        XCTAssertThrowsError(
            try RemoteSyncAISettingsPatchApplyService(
                snapshotService: snapshotService
            ).applyPatchArchives(
                [validArchive, malformedArchive],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncBoundedFileError, .malformedGzip)
        }

        XCTAssertEqual(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            ),
            graphBeforeReplay
        )
        XCTAssertEqual(
            settingsStore.getString(RemoteSyncAISettingsSnapshotService.acceptedBaselineKey),
            baselineBeforeReplay
        )
        XCTAssertEqual(
            try RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .aiSettings),
            logsBeforeReplay
        )
        XCTAssertEqual(
            try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statusesStrict(for: .aiSettings),
            statusesBeforeReplay
        )
        XCTAssertEqual(
            try modelContext.fetch(FetchDescriptor<LLMRawLogRecord>()).map(\.id),
            [fixtureIDs.rawLog]
        )
        XCTAssertEqual(
            credentialStore.credential(for: fixtureIDs.provider),
            "destination-only-secret"
        )
    }
}

/**
 Creates an isolated SwiftData container for all AI sync models plus local settings metadata.

 - Returns: Empty in-memory store containing seven synchronized AI models, raw logs, and `Setting`.
 - Side effects: Allocates transient in-process SwiftData storage only.
 - Throws: Rethrows schema or model-container initialization failures.
 */
@MainActor
private func makeAISettingsSyncContainer() throws -> ModelContainer {
    let schema = Schema(
        AIModelRegistration.cloudSyncableModels
            + AIModelRegistration.localOnlyModels
            + [Setting.self]
    )
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Inserts one value-rich row in each synchronized Android table plus one device-local raw log.

 - Parameter modelContext: Empty AI settings test context receiving the fixture.
 - Returns: Stable identities used to verify every restored table.
 - Side effects: Inserts eight SwiftData rows and saves the context once without journaling.
 - Throws: Rethrows SwiftData save failures.
 */
@MainActor
private func insertCompleteAISettingsFixture(
    into modelContext: ModelContext
) throws -> AISettingsSyncFixtureIDs {
    let ids = AISettingsSyncFixtureIDs(
        provider: UUID(uuidString: "a2000000-0000-0000-0000-000000000001")!,
        configuredModel: UUID(uuidString: "a3000000-0000-0000-0000-000000000001")!,
        agentPrompt: UUID(uuidString: "a4000000-0000-0000-0000-000000000001")!,
        usageRecord: UUID(uuidString: "a6000000-0000-0000-0000-000000000001")!,
        promptCategory: UUID(uuidString: "a5000000-0000-0000-0000-000000000001")!,
        builtinOverride: UUID(uuidString: "a7000000-0000-0000-0000-000000000001")!,
        rawLog: UUID(uuidString: "a8000000-0000-0000-0000-000000000001")!
    )

    modelContext.insert(
        LLMProviderConfig(
            id: ids.provider,
            provider: .custom,
            displayName: "Private compatible provider",
            endpoint: "https://llm.example.invalid/v1",
            apiFormat: .anthropic,
            orderNumber: 4
        )
    )
    modelContext.insert(
        LLMConfiguredModel(
            id: ids.configuredModel,
            providerConfigId: ids.provider,
            modelId: "model/with unicode λ",
            orderNumber: 3,
            inputPricePerMillion: 1.25,
            outputPricePerMillion: 5.5,
            cacheCreationPricePerMillion: 0.75,
            cacheReadPricePerMillion: 0.125
        )
    )
    modelContext.insert(
        PromptCategory(
            id: ids.promptCategory,
            name: "Study, custom",
            orderNumber: 8,
            hidden: true
        )
    )
    modelContext.insert(
        AgentPrompt(
            id: ids.agentPrompt,
            name: "Compare translations",
            description: "Preserve Android converter values",
            promptTemplate: "Compare {{selection}}\nwithout truncation.",
            showIn: [.verseSelection, .workspaceMenu],
            orderNumber: 6,
            createdAtMilliseconds: 1_725_000_000_123,
            strictContextMatching: false,
            permissionMode: .askOncePerRun,
            allowedTools: [.getVerseContent, .searchBible],
            deniedTools: [.createBookmark],
            configuredModelId: ids.configuredModel,
            specifyBeforeRun: true,
            noDocumentCreation: true,
            maxIterations: 7,
            autoIncludeDocuments: true,
            autoIncludeCommentaries: true,
            bibleOnly: true,
            isTextTransformation: false,
            categoryId: ids.promptCategory
        )
    )
    let globalSettings = GlobalAISettings()
    globalSettings.agentPermissionModeRawValue = AIPermissionMode.denyAll.rawValue
    globalSettings.permanentlyAllowedToolsRawValue = #"["GET_VERSE_CONTENT"]"#
    globalSettings.permanentlyDeniedToolsRawValue = #"["CREATE_BOOKMARK"]"#
    globalSettings.aiExcludedDocumentsRawValue = #"["KJV","NET"]"#
    globalSettings.commentaryMaxResponseTokens = 12_345
    globalSettings.hiddenBuiltInPromptsRawValue = #"["11111111-1111-1111-1111-111111111111"]"#
    globalSettings.maxIterations = 9
    globalSettings.commentaryDeselectedRawValue = #"["MHCC"]"#
    globalSettings.defaultModelId = ids.configuredModel
    globalSettings.aiLanguage = "fi-FI"
    globalSettings.askModelBeforeRun = true
    globalSettings.aiDisclaimerAccepted = true
    globalSettings.hiddenBuiltInCategoriesRawValue = #"["22222222-2222-2222-2222-222222222222"]"#
    globalSettings.customAgentSystemPrompt = "Use installed documents first."
    globalSettings.customTextTransformationSystemPrompt = "Return only transformed text."
    globalSettings.favoritePromptsRawValue = #"["33333333-3333-3333-3333-333333333333"]"#
    globalSettings.rawLogRetentionDays = 14
    globalSettings.autoHideAgentLogOnCompletion = true
    modelContext.insert(globalSettings)

    let usage = LLMUsageRecord(
        id: ids.usageRecord,
        configuredModelId: ids.configuredModel,
        deviceId: "ios-test-device"
    )
    usage.inputTokens = 101
    usage.outputTokens = 202
    usage.cacheCreationTokens = 303
    usage.cacheReadTokens = 404
    usage.estimatedCostUSD = 1.2345
    modelContext.insert(usage)
    modelContext.insert(
        BuiltInPromptOverride(
            id: ids.builtinOverride,
            configuredModelId: ids.configuredModel
        )
    )
    modelContext.insert(
        LLMRawLogRecord(
            id: ids.rawLog,
            promptId: ids.agentPrompt,
            promptName: "Device-local run",
            promptDescription: "Must not leave this device",
            configuredModelId: ids.configuredModel,
            modelName: "model/with unicode λ",
            providerType: "CUSTOM",
            timestampMilliseconds: 1_725_000_000_999,
            totalInputTokens: 10,
            totalOutputTokens: 20,
            estimatedCostUSD: 0.001,
            logData: Data("source-device-local-raw-log".utf8),
            iterationCount: 2,
            wasError: false
        )
    )
    try modelContext.save()
    return ids
}

/**
 Builds a complete strict snapshot containing one provider and no dependent rows.

 - Parameters:
   - id: Stable provider UUID used by patch log metadata.
   - displayName: Provider value expected after an accepted UPSERT.
 - Returns: Credential-free Android-shaped current snapshot.
 - Side effects: Allocates and reads a transient SwiftData container.
 - Throws: Rethrows container, save, or strict snapshot failures.
 */
@MainActor
private func makeProviderSnapshot(
    id: UUID,
    displayName: String
) throws -> RemoteSyncAISettingsCurrentSnapshot {
    let container = try makeAISettingsSyncContainer()
    let context = ModelContext(container)
    context.insert(LLMProviderConfig(id: id, provider: .openAI, displayName: displayName))
    try context.save()
    return try makeCredentialFreeAISettingsSnapshotService().snapshotCurrentStateStrict(
        modelContext: context,
        settingsStore: SettingsStore(modelContext: context)
    )
}

/**
 Builds an empty complete strict snapshot suitable for a delete-only sparse patch.

 - Returns: Android-shaped snapshot with no synchronized rows or fingerprints.
 - Side effects: Allocates and reads a transient SwiftData container.
 - Throws: Rethrows container or strict snapshot failures.
 */
@MainActor
private func makeEmptyAISettingsSnapshot() throws -> RemoteSyncAISettingsCurrentSnapshot {
    let container = try makeAISettingsSyncContainer()
    let context = ModelContext(container)
    return try makeCredentialFreeAISettingsSnapshotService().snapshotCurrentStateStrict(
        modelContext: context,
        settingsStore: SettingsStore(modelContext: context)
    )
}

/**
 Creates one canonical UUID-keyed Android AI settings log entry.

 - Parameters:
   - tableName: One of Android's seven synchronized AI table names.
   - id: UUID stored as Android's exact 16-byte BLOB primary identifier.
   - type: UPSERT or DELETE operation.
   - lastUpdated: Conflict timestamp in epoch milliseconds.
   - sourceDevice: Originating Android-compatible device identifier.
 - Returns: Log entry with Android's empty-text secondary identifier.
 - Side effects: none.
 - Failure modes: This helper cannot fail.
 */
private func aiSettingsLogEntry(
    tableName: String,
    id: UUID,
    type: RemoteSyncLogEntryType,
    lastUpdated: Int64,
    sourceDevice: String
) -> RemoteSyncLogEntry {
    RemoteSyncLogEntry(
        tableName: tableName,
        entityID1: .blob(aiSettingsUUIDBlob(id)),
        entityID2: .text(""),
        type: type,
        lastUpdated: lastUpdated,
        sourceDevice: sourceDevice
    )
}

/**
 Encodes a UUID using Android Room's raw 16-byte UUID converter representation.

 - Parameter id: UUID to encode without textual normalization.
 - Returns: Sixteen bytes in the UUID tuple's canonical order.
 - Side effects: none.
 - Failure modes: This helper cannot fail.
 */
private func aiSettingsUUIDBlob(_ id: UUID) -> Data {
    withUnsafeBytes(of: id.uuid) { Data($0) }
}

/**
 Writes and gzip-stages one sparse Android v23 AI settings patch.

 - Parameters:
   - snapshot: Complete source generation used to resolve selected UPSERT rows.
   - logEntries: Exact sparse operations and conflict metadata.
   - sourceDevice: Device folder name owning the patch stream.
   - patchNumber: Monotonic patch number within that stream.
   - fileTimestamp: Remote metadata timestamp recorded in patch status.
 - Returns: Staged archive whose temporary gzip file remains caller-owned.
 - Side effects: Creates, reads, and removes a temporary SQLite file, then writes one gzip archive.
 - Throws: Rethrows writer, compression, and filesystem failures.
 */
private func makeAISettingsPatchArchive(
    snapshot: RemoteSyncAISettingsCurrentSnapshot,
    logEntries: [RemoteSyncLogEntry],
    sourceDevice: String,
    patchNumber: Int64,
    fileTimestamp: Int64
) throws -> RemoteSyncStagedPatchArchive {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-ai-settings-patch-\(UUID().uuidString).sqlite3")
    defer { try? FileManager.default.removeItem(at: databaseURL) }
    _ = try RemoteSyncAISettingsDatabaseWriter().writeSparseDatabase(
        at: databaseURL,
        snapshot: snapshot,
        selectedLogEntries: logEntries
    )
    let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: databaseURL))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-ai-settings-patch-\(UUID().uuidString).sqlite3.gz")
    try archiveData.write(to: archiveURL, options: .atomic)
    let parentID = "/org.andbible.ios-sync-ai_settings/\(sourceDevice)"
    return RemoteSyncStagedPatchArchive(
        patch: RemoteSyncDiscoveredPatch(
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: RemoteSyncCategory.aiSettings.currentSchemaVersion,
            file: RemoteSyncFile(
                id: "\(parentID)/\(patchNumber).sqlite3.gz",
                name: "\(patchNumber).sqlite3.gz",
                size: Int64(archiveData.count),
                timestamp: fileTimestamp,
                parentID: parentID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        ),
        archiveFileURL: archiveURL
    )
}

/**
 Creates one unique temporary directory for AI settings file and outbox tests.

 - Returns: Existing empty directory beneath the process temporary root.
 - Side effects: Creates one filesystem directory; callers remove it with their test cleanup.
 - Throws: Rethrows directory creation failures.
 */
private func makeAISettingsTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-ai-settings-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    return directoryURL
}

/**
 Reads one required SQLite integer scalar from a published test database.

 - Parameters:
   - sql: Single-row integer query.
   - databaseURL: Existing SQLite file opened read-only.
 - Returns: First column of the first result row.
 - Side effects: Opens, prepares, steps, finalizes, and closes a read-only SQLite connection.
 - Throws: `RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase` for any open or query failure.
 */
private func sqliteInteger(_ sql: String, databaseURL: URL) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        sqlite3_finalize(statement)
        throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
        throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
    }
    return sqlite3_column_int64(statement, 0)
}

/**
 Adds one raw-log row that Android's whole-database initial upload can legitimately contain.

 - Parameter databaseURL: Existing exact Android v23 AI database opened for one fixture mutation.
 - Side effects: Inserts one bounded `LlmRawLogRecord` row and closes the SQLite connection.
 - Throws: `RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase` if open or insertion fails.
 */
private func insertAndroidRawLogFixture(into databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(database) }

    let sql = """
    INSERT INTO LlmRawLogRecord (
        id, promptId, promptName, promptDescription, configuredModelId, modelName, providerType,
        timestamp, totalInputTokens, totalOutputTokens, estimatedCostUsd, logData, iterationCount,
        wasError
    ) VALUES (
        X'A8000000000000000000000000000099', NULL, 'Android local run', NULL, NULL,
        'android-model', 'CUSTOM', 1725000000999, 10, 20, 0.001,
        X'616E64726F69642D6F726967696E2D7261772D6C6F67', 2, 0
    );
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
    }
}
