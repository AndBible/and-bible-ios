// RemoteSyncAISettingsSnapshotService.swift -- Android-shaped AI settings snapshots for remote sync

import CryptoKit
import Foundation
import SwiftData

/** One Android `LlmProviderConfig` row without credentials. */
public struct RemoteSyncAndroidAIProvider: Codable, Sendable, Equatable {
    public let id: UUID
    public let providerType: String
    public let displayName: String
    public let endpoint: String?
    public let apiFormat: String?
    public let orderNumber: Int
}

/** One Android `LlmConfiguredModel` row. */
public struct RemoteSyncAndroidAIConfiguredModel: Codable, Sendable, Equatable {
    public let id: UUID
    public let providerConfigId: UUID
    public let modelId: String
    public let orderNumber: Int
    public let inputPricePerMillion: Double
    public let outputPricePerMillion: Double
    public let cacheCreationPricePerMillion: Double
    public let cacheReadPricePerMillion: Double
}

/** One Android `AgentPrompt` row with Room-converter values preserved verbatim. */
public struct RemoteSyncAndroidAIAgentPrompt: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let promptDescription: String?
    public let promptTemplate: String
    public let showIn: String
    public let orderNumber: Int
    public let createdAt: Int64
    public let strictContextMatching: Bool
    public let permissionMode: String?
    public let allowedTools: String?
    public let deniedTools: String?
    public let configuredModelId: UUID?
    public let editBeforeRun: Bool
    public let noDocumentCreation: Bool
    public let maxIterations: Int?
    public let autoIncludeDocuments: Bool
    public let autoIncludeCommentaries: Bool
    public let bibleOnly: Bool
    public let isTextTransformation: Bool
    public let categoryId: UUID?
}

/** Android's singleton `GlobalAiSettings` row. */
public struct RemoteSyncAndroidGlobalAISettings: Codable, Sendable, Equatable {
    public let id: UUID
    public let agentPermissionMode: String?
    public let permanentlyAllowedTools: String?
    public let permanentlyDeniedTools: String?
    public let aiExcludedDocuments: String
    public let commentaryMaxResponseTokens: Int
    public let hiddenBuiltInPrompts: String
    public let maxIterations: Int
    public let commentaryDeselected: String
    public let defaultModelId: UUID?
    public let aiLanguage: String?
    public let askModelBeforeRun: Bool
    public let aiDisclaimerAccepted: Bool
    public let hiddenBuiltInCategories: String
    public let customAgentSystemPrompt: String?
    public let customTextTransformationSystemPrompt: String?
    public let favoritePrompts: String
    public let rawLogRetentionDays: Int?
    public let autoHideAgentLogOnCompletion: Bool
}

/** One Android `LlmUsageRecord` row. */
public struct RemoteSyncAndroidAIUsageRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let configuredModelId: UUID
    public let deviceId: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64
    public let estimatedCostUsd: Double
}

/** One Android `PromptCategory` row. */
public struct RemoteSyncAndroidAIPromptCategory: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let orderNumber: Int
    public let hidden: Bool
}

/** One Android `BuiltinPromptOverride` row. */
public struct RemoteSyncAndroidAIBuiltinPromptOverride: Codable, Sendable, Equatable {
    public let id: UUID
    public let configuredModelId: UUID?
}

/**
 Complete current AI settings projection expressed as Android v23 rows.

 `LLMRawLogRecord` is intentionally absent because Android excludes it from the `AI_SETTINGS`
 sync-table list. Provider credentials are also absent because they live only in `AICredentialStore`.
 */
public struct RemoteSyncAISettingsCurrentSnapshot: Sendable, Equatable {
    public let providerRowsByKey: [String: RemoteSyncAndroidAIProvider]
    public let configuredModelRowsByKey: [String: RemoteSyncAndroidAIConfiguredModel]
    public let agentPromptRowsByKey: [String: RemoteSyncAndroidAIAgentPrompt]
    public let globalSettingsRowsByKey: [String: RemoteSyncAndroidGlobalAISettings]
    public let usageRowsByKey: [String: RemoteSyncAndroidAIUsageRecord]
    public let promptCategoryRowsByKey: [String: RemoteSyncAndroidAIPromptCategory]
    public let builtinOverrideRowsByKey: [String: RemoteSyncAndroidAIBuiltinPromptOverride]
    public let fingerprintsByKey: [String: String]
}

/** Durable Android identity for one accepted AI settings row. */
struct RemoteSyncAISettingsAcceptedRowIdentity: Codable, Sendable, Equatable {
    let key: String
    let tableName: String
    let entityID1: RemoteSyncSQLiteValue
    let entityID2: RemoteSyncSQLiteValue
}

/** Immutable accepted fingerprint and row-identity generation for AI settings. */
struct RemoteSyncAISettingsAcceptedBaseline: Codable, Sendable, Equatable {
    let revision: UUID?
    let fingerprintsByKey: [String: String]
    let rowIdentities: [RemoteSyncAISettingsAcceptedRowIdentity]

    init(
        revision: UUID? = UUID(),
        fingerprintsByKey: [String: String],
        rowIdentities: [RemoteSyncAISettingsAcceptedRowIdentity]
    ) {
        self.revision = revision
        self.fingerprintsByKey = fingerprintsByKey
        self.rowIdentities = rowIdentities
    }
}

/** Fail-closed AI settings projection and accepted-generation errors. */
enum RemoteSyncAISettingsSnapshotError: Error, Equatable {
    case duplicateIdentifier(table: String, id: UUID)
    case duplicateProviderModel(providerID: UUID, modelID: String)
    case duplicateUsageRecord(modelID: UUID, deviceID: String)
    case invalidGlobalSettingsIdentity(UUID)
    case duplicateGlobalSettings
    case invalidFloatingPointValue(table: String, id: UUID)
    case invalidFormalReference(table: String, id: UUID, column: String, referencedID: UUID)
    case credentialLookupFailed(providerID: UUID)
    case unsafeSynchronizedEndpoint(providerID: UUID)
    case missingProjectedFingerprint(String)
    case invalidStoredBaseline
    case invalidFingerprintKey(String)
    case staleAcceptedBaseline
}

/**
 Projects SwiftData AI settings into Android's seven synchronized v23 tables.

 Data dependencies:
 - the seven models in `AIModelRegistration.cloudSyncableModels`
 - `SettingsStore` for Android-compatible log identity keys and accepted-generation storage

 Side effects:
 - strict snapshot methods read all seven synchronized SwiftData tables
 - baseline methods read or replace AI-category fingerprint and identity metadata

 Failure modes:
 - duplicate Android identities, invalid singleton rows, non-finite prices, fetch failures, malformed
   accepted state, and stale publication revisions fail before data is published

 Important:
 - `LLMRawLogRecord` can never enter a snapshot
 - `AICredentialStore` is read only to reject endpoints that embed the provider's local credential;
   credential values are never projected or fingerprinted
 */
public final class RemoteSyncAISettingsSnapshotService {
    static let acceptedBaselineKey = "remote_sync.accepted_baseline.ai_settings"
    static let emptySecondaryEntityID = RemoteSyncSQLiteValue.text("")

    private let strictSnapshotCheckpoint: () throws -> Void
    private let credentialForProvider: (UUID) throws -> String?
    private let encoder: JSONEncoder

    /**
     Creates a production snapshot service with device-local Keychain credential inspection.

     - Side Effects: Construction creates a Keychain-backed reader; snapshots perform one lookup per
       provider without modifying credentials.
     - Failure modes: Snapshot projection fails closed when Keychain cannot distinguish a missing
       credential from an access or payload error.
     */
    public init() {
        let credentialStore = AICredentialStore.keychain()
        strictSnapshotCheckpoint = {}
        credentialForProvider = { try credentialStore.credentialStrict(for: $0) }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    /**
     Creates a service with deterministic strict-read and credential dependencies for tests.

     - Parameters:
       - strictSnapshotCheckpoint: Callback invoked before graph projection.
       - credentialForProvider: Device-local credential lookup used only for endpoint leak checks.
     - Side Effects: none until snapshot projection invokes the supplied closures.
     - Failure modes: Rethrows checkpoint and credential lookup errors.
     */
    init(
        strictSnapshotCheckpoint: @escaping () throws -> Void = {},
        credentialForProvider: @escaping (UUID) throws -> String?
    ) {
        self.strictSnapshotCheckpoint = strictSnapshotCheckpoint
        self.credentialForProvider = credentialForProvider
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    /**
     Strictly projects all synchronized AI rows into deterministic Android identities.

     - Parameters:
       - modelContext: Context containing AI settings models.
       - settingsStore: Settings store used to build category log keys.
     - Returns: Complete Android-shaped AI settings snapshot.
     - Side Effects: Reads all seven synchronized model tables.
     - Throws: Fetch, checkpoint, duplicate-identity, singleton, or fingerprint errors.
     */
    public func snapshotCurrentStateStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAISettingsCurrentSnapshot {
        try strictSnapshotCheckpoint()
        let providers = try modelContext.fetch(FetchDescriptor<LLMProviderConfig>())
        let configuredModels = try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>())
        let prompts = try modelContext.fetch(FetchDescriptor<AgentPrompt>())
        let globalSettings = try modelContext.fetch(FetchDescriptor<GlobalAISettings>())
        let usageRecords = try modelContext.fetch(FetchDescriptor<LLMUsageRecord>())
        let promptCategories = try modelContext.fetch(FetchDescriptor<PromptCategory>())
        let builtinOverrides = try modelContext.fetch(FetchDescriptor<BuiltInPromptOverride>())

        if globalSettings.count > 1 {
            throw RemoteSyncAISettingsSnapshotError.duplicateGlobalSettings
        }
        if let row = globalSettings.first, row.id != GlobalAISettings.singletonID {
            throw RemoteSyncAISettingsSnapshotError.invalidGlobalSettingsIdentity(row.id)
        }

        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        var providerRowsByKey: [String: RemoteSyncAndroidAIProvider] = [:]
        var configuredModelRowsByKey: [String: RemoteSyncAndroidAIConfiguredModel] = [:]
        var agentPromptRowsByKey: [String: RemoteSyncAndroidAIAgentPrompt] = [:]
        var globalSettingsRowsByKey: [String: RemoteSyncAndroidGlobalAISettings] = [:]
        var usageRowsByKey: [String: RemoteSyncAndroidAIUsageRecord] = [:]
        var promptCategoryRowsByKey: [String: RemoteSyncAndroidAIPromptCategory] = [:]
        var builtinOverrideRowsByKey: [String: RemoteSyncAndroidAIBuiltinPromptOverride] = [:]
        var fingerprintsByKey: [String: String] = [:]
        var providerModelKeys: Set<String> = []
        var usageCompositeKeys: Set<String> = []

        /** Inserts one UUID-keyed row after enforcing Android identity and fingerprint uniqueness. */
        func insert<Row: Encodable>(
            _ row: Row,
            id: UUID,
            tableName: String,
            into rows: inout [String: Row]
        ) throws {
            let key = Self.logKey(tableName: tableName, id: id, logStore: logStore)
            guard rows[key] == nil else {
                throw RemoteSyncAISettingsSnapshotError.duplicateIdentifier(table: tableName, id: id)
            }
            rows[key] = row
            fingerprintsByKey[key] = try fingerprintHex(for: row, tableName: tableName, id: id)
        }

        for value in providers.sorted(by: Self.providerSort) {
            let knownCredential: String?
            do {
                knownCredential = try credentialForProvider(value.id)
            } catch {
                throw RemoteSyncAISettingsSnapshotError.credentialLookupFailed(
                    providerID: value.id
                )
            }
            guard RemoteSyncAISettingsEndpointPolicy.isCredentialFree(
                value.endpoint,
                knownCredential: knownCredential
            ) else {
                throw RemoteSyncAISettingsSnapshotError.unsafeSynchronizedEndpoint(
                    providerID: value.id
                )
            }
            let row = RemoteSyncAndroidAIProvider(
                id: value.id,
                providerType: value.providerType,
                displayName: value.displayName,
                endpoint: value.endpoint,
                apiFormat: value.apiFormatRawValue,
                orderNumber: value.orderNumber
            )
            try insert(row, id: row.id, tableName: "LlmProviderConfig", into: &providerRowsByKey)
        }

        for value in configuredModels.sorted(by: Self.configuredModelSort) {
            guard value.inputPricePerMillion.isFinite,
                  value.outputPricePerMillion.isFinite,
                  value.cacheCreationPricePerMillion.isFinite,
                  value.cacheReadPricePerMillion.isFinite else {
                throw RemoteSyncAISettingsSnapshotError.invalidFloatingPointValue(
                    table: "LlmConfiguredModel",
                    id: value.id
                )
            }
            let compositeKey = "\(value.providerConfigId.uuidString.lowercased())\u{0}\(value.modelId)"
            guard providerModelKeys.insert(compositeKey).inserted else {
                throw RemoteSyncAISettingsSnapshotError.duplicateProviderModel(
                    providerID: value.providerConfigId,
                    modelID: value.modelId
                )
            }
            let row = RemoteSyncAndroidAIConfiguredModel(
                id: value.id,
                providerConfigId: value.providerConfigId,
                modelId: value.modelId,
                orderNumber: value.orderNumber,
                inputPricePerMillion: value.inputPricePerMillion,
                outputPricePerMillion: value.outputPricePerMillion,
                cacheCreationPricePerMillion: value.cacheCreationPricePerMillion,
                cacheReadPricePerMillion: value.cacheReadPricePerMillion
            )
            try insert(row, id: row.id, tableName: "LlmConfiguredModel", into: &configuredModelRowsByKey)
        }

        for value in prompts.sorted(by: Self.promptSort) {
            let row = RemoteSyncAndroidAIAgentPrompt(
                id: value.id,
                name: value.name,
                promptDescription: value.promptDescription,
                promptTemplate: value.promptTemplate,
                showIn: value.showInRawValue,
                orderNumber: value.orderNumber,
                createdAt: value.createdAtMilliseconds,
                strictContextMatching: value.strictContextMatching,
                permissionMode: value.permissionModeRawValue,
                allowedTools: value.allowedToolsRawValue,
                deniedTools: value.deniedToolsRawValue,
                configuredModelId: value.configuredModelId,
                editBeforeRun: value.specifyBeforeRun,
                noDocumentCreation: value.noDocumentCreation,
                maxIterations: value.maxIterations,
                autoIncludeDocuments: value.autoIncludeDocuments,
                autoIncludeCommentaries: value.autoIncludeCommentaries,
                bibleOnly: value.bibleOnly,
                isTextTransformation: value.isTextTransformation,
                categoryId: value.categoryId
            )
            try insert(row, id: row.id, tableName: "AgentPrompt", into: &agentPromptRowsByKey)
        }

        for value in globalSettings {
            let row = RemoteSyncAndroidGlobalAISettings(
                id: value.id,
                agentPermissionMode: value.agentPermissionModeRawValue,
                permanentlyAllowedTools: value.permanentlyAllowedToolsRawValue,
                permanentlyDeniedTools: value.permanentlyDeniedToolsRawValue,
                aiExcludedDocuments: value.aiExcludedDocumentsRawValue,
                commentaryMaxResponseTokens: value.commentaryMaxResponseTokens,
                hiddenBuiltInPrompts: value.hiddenBuiltInPromptsRawValue,
                maxIterations: value.maxIterations,
                commentaryDeselected: value.commentaryDeselectedRawValue,
                defaultModelId: value.defaultModelId,
                aiLanguage: value.aiLanguage,
                askModelBeforeRun: value.askModelBeforeRun,
                aiDisclaimerAccepted: value.aiDisclaimerAccepted,
                hiddenBuiltInCategories: value.hiddenBuiltInCategoriesRawValue,
                customAgentSystemPrompt: value.customAgentSystemPrompt,
                customTextTransformationSystemPrompt: value.customTextTransformationSystemPrompt,
                favoritePrompts: value.favoritePromptsRawValue,
                rawLogRetentionDays: value.rawLogRetentionDays,
                autoHideAgentLogOnCompletion: value.autoHideAgentLogOnCompletion
            )
            try insert(row, id: row.id, tableName: "GlobalAiSettings", into: &globalSettingsRowsByKey)
        }

        for value in usageRecords.sorted(by: Self.usageSort) {
            guard value.estimatedCostUSD.isFinite else {
                throw RemoteSyncAISettingsSnapshotError.invalidFloatingPointValue(
                    table: "LlmUsageRecord",
                    id: value.id
                )
            }
            let compositeKey = "\(value.configuredModelId.uuidString.lowercased())\u{0}\(value.deviceId)"
            guard usageCompositeKeys.insert(compositeKey).inserted else {
                throw RemoteSyncAISettingsSnapshotError.duplicateUsageRecord(
                    modelID: value.configuredModelId,
                    deviceID: value.deviceId
                )
            }
            let row = RemoteSyncAndroidAIUsageRecord(
                id: value.id,
                configuredModelId: value.configuredModelId,
                deviceId: value.deviceId,
                inputTokens: value.inputTokens,
                outputTokens: value.outputTokens,
                cacheCreationTokens: value.cacheCreationTokens,
                cacheReadTokens: value.cacheReadTokens,
                estimatedCostUsd: value.estimatedCostUSD
            )
            try insert(row, id: row.id, tableName: "LlmUsageRecord", into: &usageRowsByKey)
        }

        for value in promptCategories.sorted(by: Self.categorySort) {
            let row = RemoteSyncAndroidAIPromptCategory(
                id: value.id,
                name: value.name,
                orderNumber: value.orderNumber,
                hidden: value.hidden
            )
            try insert(row, id: row.id, tableName: "PromptCategory", into: &promptCategoryRowsByKey)
        }

        for value in builtinOverrides.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let row = RemoteSyncAndroidAIBuiltinPromptOverride(
                id: value.id,
                configuredModelId: value.configuredModelId
            )
            try insert(row, id: row.id, tableName: "BuiltinPromptOverride", into: &builtinOverrideRowsByKey)
        }

        let providerIDs = Set(providerRowsByKey.values.map(\.id))
        for row in configuredModelRowsByKey.values where !providerIDs.contains(row.providerConfigId) {
            throw RemoteSyncAISettingsSnapshotError.invalidFormalReference(
                table: "LlmConfiguredModel",
                id: row.id,
                column: "providerConfigId",
                referencedID: row.providerConfigId
            )
        }
        let configuredModelIDs = Set(configuredModelRowsByKey.values.map(\.id))
        for row in agentPromptRowsByKey.values {
            if let configuredModelId = row.configuredModelId,
               !configuredModelIDs.contains(configuredModelId) {
                throw RemoteSyncAISettingsSnapshotError.invalidFormalReference(
                    table: "AgentPrompt",
                    id: row.id,
                    column: "configuredModelId",
                    referencedID: configuredModelId
                )
            }
        }
        for row in builtinOverrideRowsByKey.values {
            if let configuredModelId = row.configuredModelId,
               !configuredModelIDs.contains(configuredModelId) {
                throw RemoteSyncAISettingsSnapshotError.invalidFormalReference(
                    table: "BuiltinPromptOverride",
                    id: row.id,
                    column: "configuredModelId",
                    referencedID: configuredModelId
                )
            }
        }

        return RemoteSyncAISettingsCurrentSnapshot(
            providerRowsByKey: providerRowsByKey,
            configuredModelRowsByKey: configuredModelRowsByKey,
            agentPromptRowsByKey: agentPromptRowsByKey,
            globalSettingsRowsByKey: globalSettingsRowsByKey,
            usageRowsByKey: usageRowsByKey,
            promptCategoryRowsByKey: promptCategoryRowsByKey,
            builtinOverrideRowsByKey: builtinOverrideRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /** Converts a strict snapshot into an immutable accepted generation. */
    func acceptedBaseline(
        from snapshot: RemoteSyncAISettingsCurrentSnapshot
    ) throws -> RemoteSyncAISettingsAcceptedBaseline {
        let identities = acceptedRowIdentities(from: snapshot)
        for identity in identities where snapshot.fingerprintsByKey[identity.key] == nil {
            throw RemoteSyncAISettingsSnapshotError.missingProjectedFingerprint(identity.key)
        }
        return RemoteSyncAISettingsAcceptedBaseline(
            fingerprintsByKey: snapshot.fingerprintsByKey,
            rowIdentities: identities
        )
    }

    /** Reads the accepted AI settings generation, failing on malformed persisted JSON. */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAISettingsAcceptedBaseline? {
        guard let payload = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(RemoteSyncAISettingsAcceptedBaseline.self, from: data) else {
            throw RemoteSyncAISettingsSnapshotError.invalidStoredBaseline
        }
        return baseline
    }

    /** Verifies that an outbox still targets the accepted generation used during projection. */
    func validateAcceptedBaselineRevision(
        expectedRevision: UUID?,
        expectedBaselineExists: Bool,
        settingsStore: SettingsStore
    ) throws {
        let current = try storedAcceptedBaseline(settingsStore: settingsStore)
        guard (current != nil) == expectedBaselineExists,
              current?.revision == expectedRevision else {
            throw RemoteSyncAISettingsSnapshotError.staleAcceptedBaseline
        }
    }

    /** Replaces AI settings fingerprints and accepted row identities atomically with the caller. */
    func acceptBaseline(
        _ baseline: RemoteSyncAISettingsAcceptedBaseline,
        settingsStore: SettingsStore
    ) throws {
        let fingerprints = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprints.prefix(for: .aiSettings)
        let logPrefix = logStore.prefix(for: .aiSettings)

        fingerprints.clearCategory(.aiSettings)
        for (logKey, fingerprint) in baseline.fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard logKey.hasPrefix(logPrefix) else {
                throw RemoteSyncAISettingsSnapshotError.invalidFingerprintKey(logKey)
            }
            settingsStore.setString(
                "\(fingerprintPrefix)\(logKey.dropFirst(logPrefix.count))",
                value: fingerprint
            )
        }

        let data = try encoder.encode(baseline)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncAISettingsSnapshotError.invalidStoredBaseline
        }
        settingsStore.setString(Self.acceptedBaselineKey, value: payload)
    }

    /** Strictly refreshes the accepted baseline from the current SwiftData graph. */
    func refreshBaselineFingerprintsStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let snapshot = try snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try acceptBaseline(try acceptedBaseline(from: snapshot), settingsStore: settingsStore)
    }

    /** Returns the Android identity manifest for every row in one snapshot. */
    private func acceptedRowIdentities(
        from snapshot: RemoteSyncAISettingsCurrentSnapshot
    ) -> [RemoteSyncAISettingsAcceptedRowIdentity] {
        var result: [RemoteSyncAISettingsAcceptedRowIdentity] = []

        /** Appends identities for one UUID-keyed Android table map. */
        func append<Row>(_ rows: [String: Row], tableName: String, id: (Row) -> UUID) {
            for (key, row) in rows {
                result.append(
                    RemoteSyncAISettingsAcceptedRowIdentity(
                        key: key,
                        tableName: tableName,
                        entityID1: .blob(Self.uuidBlob(id(row))),
                        entityID2: Self.emptySecondaryEntityID
                    )
                )
            }
        }

        append(snapshot.providerRowsByKey, tableName: "LlmProviderConfig", id: \.id)
        append(snapshot.configuredModelRowsByKey, tableName: "LlmConfiguredModel", id: \.id)
        append(snapshot.agentPromptRowsByKey, tableName: "AgentPrompt", id: \.id)
        append(snapshot.globalSettingsRowsByKey, tableName: "GlobalAiSettings", id: \.id)
        append(snapshot.usageRowsByKey, tableName: "LlmUsageRecord", id: \.id)
        append(snapshot.promptCategoryRowsByKey, tableName: "PromptCategory", id: \.id)
        append(snapshot.builtinOverrideRowsByKey, tableName: "BuiltinPromptOverride", id: \.id)
        return result.sorted { $0.key < $1.key }
    }

    /** Produces Android's raw 16-byte UUID representation. */
    static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /** Decodes a 16-byte Android UUID blob. */
    static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { bytes -> UUID? in
            guard bytes.count == 16 else { return nil }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }

    /** Builds the canonical settings-backed log key for one UUID row. */
    static func logKey(
        tableName: String,
        id: UUID,
        logStore: RemoteSyncLogEntryStore
    ) -> String {
        logStore.key(
            for: .aiSettings,
            tableName: tableName,
            entityID1: .blob(uuidBlob(id)),
            entityID2: emptySecondaryEntityID
        )
    }

    /** Encodes one row deterministically and hashes its complete non-secret wire state. */
    private func fingerprintHex<Row: Encodable>(
        for row: Row,
        tableName: String,
        id: UUID
    ) throws -> String {
        do {
            let data = try encoder.encode(row)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw RemoteSyncAISettingsSnapshotError.invalidFloatingPointValue(
                table: tableName,
                id: id
            )
        }
    }

    private static func providerSort(_ lhs: LLMProviderConfig, _ rhs: LLMProviderConfig) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func configuredModelSort(
        _ lhs: LLMConfiguredModel,
        _ rhs: LLMConfiguredModel
    ) -> Bool {
        if lhs.providerConfigId != rhs.providerConfigId {
            return lhs.providerConfigId.uuidString < rhs.providerConfigId.uuidString
        }
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.modelId != rhs.modelId { return lhs.modelId < rhs.modelId }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func promptSort(_ lhs: AgentPrompt, _ rhs: AgentPrompt) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.createdAtMilliseconds != rhs.createdAtMilliseconds {
            return lhs.createdAtMilliseconds < rhs.createdAtMilliseconds
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func usageSort(_ lhs: LLMUsageRecord, _ rhs: LLMUsageRecord) -> Bool {
        if lhs.configuredModelId != rhs.configuredModelId {
            return lhs.configuredModelId.uuidString < rhs.configuredModelId.uuidString
        }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func categorySort(_ lhs: PromptCategory, _ rhs: PromptCategory) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/** Credential boundary shared by outbound snapshots and inbound AI settings restore. */
enum RemoteSyncAISettingsEndpointPolicy {
    /// Normalized short query names that conventionally carry authentication material.
    private static let credentialQueryNames: Set<String> = [
        "accesskey",
        "accesstoken",
        "apikey",
        "auth",
        "authorization",
        "authtoken",
        "code",
        "credential",
        "credentials",
        "key",
        "password",
        "passwd",
        "secret",
        "sig",
        "signature",
        "token",
    ]

    /// Longer markers rejected anywhere inside a normalized query or path component name.
    private static let credentialNameFragments = [
        "accesskey",
        "accesstoken",
        "apikey",
        "authorization",
        "authtoken",
        "credential",
        "password",
        "secret",
        "securitytoken",
        "sessiontoken",
        "signature",
    ]

    /// Prefix and minimum token lengths that distinguish credentials from short routing labels.
    private static let credentialValuePrefixRules: [(prefix: String, minimumLength: Int)] = [
        ("aiza", 24),
        ("akia", 20),
        ("github_pat_", 24),
        ("ghp_", 24),
        ("rk-", 20),
        ("sk-", 20),
        ("sk_", 20),
        ("xoxa-", 20),
        ("xoxb-", 20),
        ("xoxp-", 20),
        ("xoxr-", 20),
        ("xoxs-", 20),
    ]

    /**
     Returns whether one optional provider endpoint is safe to synchronize as non-secret state.

     - Parameters:
       - endpoint: Persisted custom endpoint string, or `nil` for known providers.
       - knownCredential: Device-local provider credential, when available on the sending device.
     - Returns: `false` for URL user-info, fragments, signed/auth query families, credential-bearing
       path labels, realistic token values, or any recursively decoded endpoint form that embeds the
       provider's exact local credential. Hostnames and short routing labels are not token-scanned.
     - Side Effects: none.
     - Failure modes: Endpoints that `URLComponents` cannot parse fail closed before publication.
     */
    static func isCredentialFree(
        _ endpoint: String?,
        knownCredential: String? = nil
    ) -> Bool {
        guard let endpoint else { return true }
        if let knownCredential, !knownCredential.isEmpty {
            guard !percentDecodedForms(endpoint).contains(where: {
                $0.contains(knownCredential)
            }) else {
                return false
            }
        }
        guard let components = URLComponents(string: endpoint) else { return false }
        guard components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return false
        }
        let pathComponents = components.percentEncodedPath.split(separator: "/")
        guard !pathComponents.contains(where: { component in
            let value = String(component)
            return isCredentialName(value)
                || containsRecognizableCredentialValue(in: value)
        }) else {
            return false
        }
        return !(components.queryItems ?? []).contains { item in
            isCredentialName(item.name)
                || containsRecognizableCredentialValue(in: item.value ?? "")
        }
    }

    /** Normalizes common punctuation and case differences in one query key. */
    private static func normalizedQueryName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /** Classifies exact and vendor-prefixed authentication field names after punctuation removal. */
    private static func isCredentialName(_ value: String) -> Bool {
        percentDecodedForms(value).contains { form in
            let normalized = normalizedQueryName(form)
            return credentialQueryNames.contains(normalized)
                || credentialNameFragments.contains(where: normalized.contains)
        }
    }

    /** Detects realistic opaque token forms through every reversible percent-decoding layer. */
    private static func containsRecognizableCredentialValue(in value: String) -> Bool {
        percentDecodedForms(value).contains { form in
            let lowercased = form.lowercased()
            if lowercased.contains("bearer ") {
                return true
            }
            let tokens = lowercased.split { character in
                !(character.isLetter
                    || character.isNumber
                    || character == "-"
                    || character == "_"
                    || character == ".")
            }
            return tokens.contains { token in
                credentialValuePrefixRules.contains(where: { rule in
                    token.hasPrefix(rule.prefix) && token.count >= rule.minimumLength
                })
                    || (token.hasPrefix("eyj")
                        && token.count >= 24
                        && token.filter { $0 == "." }.count == 2)
            }
        }
    }

    /**
     Produces every successively decoded representation until percent decoding reaches a fixed point.

     Each successful non-identity decode shortens the input, so the byte-count bound guarantees
     deterministic termination without imposing a bypassable fixed nesting depth.
     */
    private static func percentDecodedForms(_ value: String) -> [String] {
        var forms = [value]
        var current = value
        for _ in 0..<value.utf8.count {
            guard let decoded = current.removingPercentEncoding,
                  decoded != current else {
                break
            }
            forms.append(decoded)
            current = decoded
        }
        return forms
    }
}
