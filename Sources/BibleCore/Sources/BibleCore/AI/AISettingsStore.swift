import Foundation
import SwiftData

/**
 Errors raised when AI settings invariants cannot be maintained.
 */
public enum AISettingsStoreError: Error, Equatable, Sendable {
    /// A model references a provider that does not exist.
    case providerNotFound(UUID)

    /// A requested configured model does not exist.
    case modelNotFound(UUID)
}

/**
 Owns SwiftData access for Android v23 AI settings and local raw logs.

 The store expects a context whose container includes both `AIModelRegistration` groups. Every
 mutation saves synchronously on the main actor so callers do not observe an in-memory state that
 has not reached SwiftData. Credentials are intentionally outside this API.

 - Important: `ModelContext` confinement makes this type main-actor isolated.
 */
@MainActor
public final class AISettingsStore {
    /// Context used for all AI model reads and writes.
    private let modelContext: ModelContext

    /**
     Creates a store bound to one SwiftData context.

     - Parameter modelContext: Context whose schema includes the registered AI models.
     - Side effects: none.
     - Failure modes: Missing model registrations surface when a fetch or save is attempted.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     Returns Android's singleton global settings, creating and saving v23 defaults when absent.

     - Returns: The managed singleton settings row.
     - Side effects: Inserts and saves a default row on first access.
     - Throws: SwiftData fetch or save errors.
     */
    public func globalSettings() throws -> GlobalAISettings {
        var descriptor = FetchDescriptor<GlobalAISettings>()
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        }
        let settings = GlobalAISettings()
        modelContext.insert(settings)
        try modelContext.save()
        return settings
    }

    /** Saves mutations already made to managed AI models. */
    public func save() throws {
        try modelContext.save()
    }

    /**
     Persists whether the user explicitly accepted Android's AI responsibility notice.

     The mutation runs in one SwiftData transaction. Any fetch or commit failure rolls the supplied
     context back before the error escapes, so a failed save cannot leave an in-memory `true` value
     that bypasses the disclaimer or becomes durable during a later unrelated save.

     - Parameter isAccepted: Whether protected AI configuration actions may proceed.
     - Side effects: Updates and saves the singleton `GlobalAISettings` row.
     - Throws: SwiftData fetch, transaction, or save errors after rolling back pending changes.
     - Important: As with every mutating store operation, callers must not concurrently mutate the
       bound `ModelContext` while this method runs.
    */
    public func setDisclaimerAccepted(_ isAccepted: Bool) throws {
        let settings = try globalSettings()
        let previousValue = settings.aiDisclaimerAccepted
        do {
            try modelContext.transaction {
                settings.aiDisclaimerAccepted = isAccepted
            }
        } catch {
            modelContext.rollback()
            settings.aiDisclaimerAccepted = previousValue
            throw error
        }
    }

    /** Returns provider configurations in Android display order. */
    public func providers() throws -> [LLMProviderConfig] {
        var descriptor = FetchDescriptor<LLMProviderConfig>(
            sortBy: [SortDescriptor(\.orderNumber), SortDescriptor(\.displayName)]
        )
        descriptor.includePendingChanges = true
        return try modelContext.fetch(descriptor)
    }

    /** Returns a provider by stable identity, or `nil` when it was removed. */
    public func provider(id: UUID) throws -> LLMProviderConfig? {
        var descriptor = FetchDescriptor<LLMProviderConfig>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /** Inserts and saves a non-secret provider configuration. */
    public func insertProvider(_ provider: LLMProviderConfig) throws {
        modelContext.insert(provider)
        try modelContext.save()
    }

    /**
     Deletes a provider and applies Android's dependent-row semantics without SwiftData relationships.

     Configured models and their usage are deleted. Prompt, global-default, and built-in override
     references to those models are cleared. Keychain deletion remains an explicit credential-store
     operation so persistence failure cannot silently orphan a still-needed secret.

     - Parameter providerID: Provider configuration to remove.
     - Side effects: Mutates and saves every affected AI settings row in one context transaction.
     - Throws: SwiftData fetch, transaction, or save errors.
     */
    public func deleteProvider(id providerID: UUID) throws {
        guard let provider = try provider(id: providerID) else { return }
        let removedModelIDs = Set(try models(providerConfigId: providerID).map(\.id))
        let settings = try globalSettings()

        try modelContext.transaction {
            for model in try allModels() where removedModelIDs.contains(model.id) {
                modelContext.delete(model)
            }
            for prompt in try userPrompts() where prompt.configuredModelId.map(removedModelIDs.contains) == true {
                prompt.configuredModelId = nil
            }
            if settings.defaultModelId.map(removedModelIDs.contains) == true {
                settings.defaultModelId = nil
            }
            for override in try builtInOverrides()
            where override.configuredModelId.map(removedModelIDs.contains) == true {
                override.configuredModelId = nil
            }
            for usage in try usageRecords() where removedModelIDs.contains(usage.configuredModelId) {
                modelContext.delete(usage)
            }
            modelContext.delete(provider)
        }
    }

    /** Returns all configured models in display order. */
    public func allModels() throws -> [LLMConfiguredModel] {
        try modelContext.fetch(
            FetchDescriptor<LLMConfiguredModel>(
                sortBy: [SortDescriptor(\.orderNumber), SortDescriptor(\.modelId)]
            )
        )
    }

    /** Returns configured models for one provider in Android display order. */
    public func models(providerConfigId: UUID) throws -> [LLMConfiguredModel] {
        try modelContext.fetch(
            FetchDescriptor<LLMConfiguredModel>(
                predicate: #Predicate { $0.providerConfigId == providerConfigId },
                sortBy: [SortDescriptor(\.orderNumber), SortDescriptor(\.modelId)]
            )
        )
    }

    /** Returns a configured model by identity, or `nil` when it was removed. */
    public func model(id: UUID) throws -> LLMConfiguredModel? {
        var descriptor = FetchDescriptor<LLMConfiguredModel>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /**
     Inserts a configured model after verifying its provider exists.

     - Throws: `AISettingsStoreError.providerNotFound` or SwiftData errors.
     */
    public func insertModel(_ model: LLMConfiguredModel) throws {
        guard try provider(id: model.providerConfigId) != nil else {
            throw AISettingsStoreError.providerNotFound(model.providerConfigId)
        }
        modelContext.insert(model)
        try modelContext.save()
    }

    /**
     Deletes one configured model and clears every dependent v23 reference.

     - Parameter modelID: Configured model identity to remove.
     - Side effects: Clears prompt/default/override references, removes usage, and deletes the model
       in one context transaction.
     - Throws: SwiftData fetch or transaction errors.
     */
    public func deleteModel(id modelID: UUID) throws {
        guard let model = try model(id: modelID) else { return }
        let settings = try globalSettings()
        try modelContext.transaction {
            for prompt in try userPrompts() where prompt.configuredModelId == modelID {
                prompt.configuredModelId = nil
            }
            if settings.defaultModelId == modelID {
                settings.defaultModelId = nil
            }
            for override in try builtInOverrides() where override.configuredModelId == modelID {
                override.configuredModelId = nil
            }
            for usage in try usageRecords() where usage.configuredModelId == modelID {
                modelContext.delete(usage)
            }
            modelContext.delete(model)
        }
    }

    /** Returns user-created prompts in Android display order. */
    public func userPrompts() throws -> [AgentPrompt] {
        try modelContext.fetch(
            FetchDescriptor<AgentPrompt>(
                sortBy: [SortDescriptor(\.orderNumber), SortDescriptor(\.createdAtMilliseconds)]
            )
        )
    }

    /** Returns a user-created prompt by identity. */
    public func userPrompt(id: UUID) throws -> AgentPrompt? {
        var descriptor = FetchDescriptor<AgentPrompt>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /** Inserts and saves a user-created prompt. */
    public func insertPrompt(_ prompt: AgentPrompt) throws {
        modelContext.insert(prompt)
        try modelContext.save()
    }

    /** Deletes and saves a user-created prompt. */
    public func deletePrompt(_ prompt: AgentPrompt) throws {
        modelContext.delete(prompt)
        try modelContext.save()
    }

    /** Returns user-created categories ordered like Android. */
    public func userCategories() throws -> [PromptCategory] {
        try modelContext.fetch(
            FetchDescriptor<PromptCategory>(
                sortBy: [SortDescriptor(\.orderNumber), SortDescriptor(\.name)]
            )
        )
    }

    /** Returns one user-created category by identity. */
    public func userCategory(id: UUID) throws -> PromptCategory? {
        var descriptor = FetchDescriptor<PromptCategory>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /** Inserts and saves a user-created category. */
    public func insertCategory(_ category: PromptCategory) throws {
        modelContext.insert(category)
        try modelContext.save()
    }

    /**
     Deletes a user category using Android's move-to-root or delete-prompts behavior.

     - Parameters:
       - categoryID: User category identity.
       - deletePrompts: Whether prompts in the category are deleted instead of uncategorized.
     - Side effects: Mutates category prompts and deletes the category in one context transaction.
     - Throws: SwiftData fetch or transaction errors.
     */
    public func deleteCategory(id categoryID: UUID, deletePrompts: Bool) throws {
        guard let category = try userCategory(id: categoryID) else { return }
        try modelContext.transaction {
            for prompt in try userPrompts() where prompt.categoryId == categoryID {
                if deletePrompts {
                    modelContext.delete(prompt)
                } else {
                    prompt.categoryId = nil
                }
            }
            modelContext.delete(category)
        }
    }

    /** Returns all persisted built-in model overrides. */
    public func builtInOverrides() throws -> [BuiltInPromptOverride] {
        try modelContext.fetch(FetchDescriptor<BuiltInPromptOverride>())
    }

    /** Returns one persisted built-in model override. */
    public func builtInOverride(id: UUID) throws -> BuiltInPromptOverride? {
        var descriptor = FetchDescriptor<BuiltInPromptOverride>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /**
     Upserts a built-in model override, or removes the row when the model is `nil`.

     - Parameters:
       - promptID: Code-owned built-in prompt identity.
       - modelID: Configured model override, or `nil` to inherit the global model.
     - Side effects: Inserts, updates, or deletes one SwiftData row and saves the context.
     - Throws: `AISettingsStoreError.modelNotFound` for a non-existent model, or SwiftData errors.
     */
    public func setBuiltInModelOverride(promptID: UUID, modelID: UUID?) throws {
        if let modelID, try model(id: modelID) == nil {
            throw AISettingsStoreError.modelNotFound(modelID)
        }
        if let existing = try builtInOverride(id: promptID) {
            if let modelID {
                existing.configuredModelId = modelID
            } else {
                modelContext.delete(existing)
            }
        } else if let modelID {
            modelContext.insert(BuiltInPromptOverride(id: promptID, configuredModelId: modelID))
        }
        try modelContext.save()
    }

    /** Returns every cumulative usage row. */
    public func usageRecords() throws -> [LLMUsageRecord] {
        try modelContext.fetch(FetchDescriptor<LLMUsageRecord>())
    }

    /**
     Atomically accumulates one provider response's usage into the device/model row.

     Negative usage values are clamped to zero so malformed provider counters cannot reduce durable
     totals. Cost is likewise non-negative.

     - Parameters:
       - usage: Provider-neutral token counts.
       - configuredModelId: Model receiving the usage.
       - deviceId: Stable local device identifier.
       - estimatedCostUSD: Incremental estimated cost.
     - Returns: The updated managed usage row.
     - Side effects: Inserts or updates and saves one SwiftData row.
     - Throws: `AISettingsStoreError.modelNotFound` or SwiftData errors.
     */
    public func recordUsage(
        _ usage: LLMUsage,
        configuredModelId: UUID,
        deviceId: String,
        estimatedCostUSD: Double
    ) throws -> LLMUsageRecord {
        guard try model(id: configuredModelId) != nil else {
            throw AISettingsStoreError.modelNotFound(configuredModelId)
        }
        let descriptor = FetchDescriptor<LLMUsageRecord>(
            predicate: #Predicate {
                $0.configuredModelId == configuredModelId && $0.deviceId == deviceId
            }
        )
        let row = try modelContext.fetch(descriptor).first ?? LLMUsageRecord(
            configuredModelId: configuredModelId,
            deviceId: deviceId
        )
        if row.modelContext == nil {
            modelContext.insert(row)
        }
        row.inputTokens += max(usage.inputTokens, 0)
        row.outputTokens += max(usage.outputTokens, 0)
        row.cacheCreationTokens += max(usage.cacheCreationTokens, 0)
        row.cacheReadTokens += max(usage.cacheReadTokens, 0)
        let cost = estimatedCostUSD.isFinite ? max(estimatedCostUSD, 0) : 0
        let updatedCost = row.estimatedCostUSD + cost
        row.estimatedCostUSD = updatedCost.isFinite ? updatedCost : .greatestFiniteMagnitude
        try modelContext.save()
        return row
    }

    /** Inserts and saves a device-local raw LLM log. */
    public func insertRawLog(_ record: LLMRawLogRecord) throws {
        modelContext.insert(record)
        try modelContext.save()
    }

    /** Returns local raw logs newest first. */
    public func rawLogs() throws -> [LLMRawLogRecord] {
        try modelContext.fetch(
            FetchDescriptor<LLMRawLogRecord>(
                sortBy: [SortDescriptor(\.timestampMilliseconds, order: .reverse)]
            )
        )
    }

    /** Deletes local raw logs older than an epoch-millisecond boundary and saves once. */
    public func deleteRawLogs(olderThan timestampMilliseconds: Int64) throws {
        let records = try modelContext.fetch(
            FetchDescriptor<LLMRawLogRecord>(
                predicate: #Predicate { $0.timestampMilliseconds < timestampMilliseconds }
            )
        )
        records.forEach(modelContext.delete)
        try modelContext.save()
    }
}

/**
 Stores provider API keys in device-only Keychain state through the app's shared secret abstraction.

 Keys use Android's `llm_api_key_<provider-id>` namespace. The default backing store is
 `KeychainSecretStore`, whose `AfterFirstUnlockThisDeviceOnly` accessibility prevents migration,
 backup restoration, SwiftData persistence, and CloudKit sync.
 */
public final class AICredentialStore {
    /// Secret backend; tests may inject a deterministic in-memory implementation.
    private let secretStore: SecretStoring

    /**
     Creates a credential store over an explicit secret backend.

     - Parameter secretStore: Keychain-backed production store or test double.
     - Side effects: none.
     - Failure modes: Backend failures occur only on write or delete.
     */
    public init(secretStore: SecretStoring) {
        self.secretStore = secretStore
    }

    /**
     Creates the production device-only Keychain credential store.

     - Parameter service: Keychain service namespace; defaults to the app bundle namespace.
     - Returns: Credential store backed by `KeychainSecretStore`.
     - Side effects: none until a credential is read or written.
     */
    public static func keychain(
        service: String = "org.andbible.BibleCore.AICredentials"
    ) -> AICredentialStore {
        AICredentialStore(secretStore: KeychainSecretStore(service: service))
    }

    /** Reads a provider API key, returning `nil` when no non-empty key exists. */
    public func credential(for providerID: UUID) -> String? {
        secretStore.secret(forKey: Self.key(for: providerID)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /**
     Inserts or updates a provider API key; an empty value removes it.

     - Parameters:
       - credential: Exact provider secret. Whitespace is preserved because some private endpoints
         use nonstandard token formats.
       - providerID: Provider configuration identity.
     - Side effects: Writes or deletes one device-only Keychain item.
     - Throws: Backend-specific Keychain errors.
     */
    public func setCredential(_ credential: String, for providerID: UUID) throws {
        if credential.isEmpty {
            try removeCredential(for: providerID)
        } else {
            try secretStore.setSecret(credential, forKey: Self.key(for: providerID))
        }
    }

    /** Deletes a provider's device-only Keychain credential. */
    public func removeCredential(for providerID: UUID) throws {
        try secretStore.removeSecret(forKey: Self.key(for: providerID))
    }

    /** Builds the stable Android-compatible Keychain account key. */
    private static func key(for providerID: UUID) -> String {
        "llm_api_key_\(providerID.uuidString.lowercased())"
    }
}
