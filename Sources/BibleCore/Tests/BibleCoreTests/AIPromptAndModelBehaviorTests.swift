import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects Android v23 prompt identity, source precedence, credential placement, and model fallback.

 Every test uses an in-memory AI-only SwiftData container and a non-Keychain secret double, so the
 suite performs no network, disk, CloudKit, backup, or system-Keychain side effects.
 */
@MainActor
final class AIPromptAndModelBehaviorTests: XCTestCase {
    /**
     Verifies Java-compatible UUID-v3 identities and the complete production catalog ordering.

     Failure means an iOS update would lose Android hidden/favorite/override identity continuity or
     omit a production action.
     */
    func testBuiltInCatalogUsesAndroidUUIDV3IdentitiesAndProductionOrder() {
        XCTAssertEqual(
            BuiltInPromptCatalog.id(forKey: "translate-ui-language"),
            UUID(uuidString: "fb526879-5a02-30f1-970c-6ba95307a999")
        )
        XCTAssertEqual(
            BuiltInPromptCatalog.id(forKey: "summary"),
            UUID(uuidString: "2cb7a27c-edb1-36bb-a51f-55abf41a4927")
        )
        XCTAssertEqual(
            BuiltInPromptCatalog.studyCategoryID,
            UUID(uuidString: "111222a5-e449-34a0-b9aa-c23666ad7090")
        )
        let prompts = BuiltInPromptCatalog.productionPrompts(responseLanguageName: "Finnish")
        XCTAssertEqual(prompts.count, 14)
        XCTAssertEqual(prompts.map(\.id), BuiltInPromptCatalog.productionKeys.map(BuiltInPromptCatalog.id))
        XCTAssertEqual(prompts.first?.name, "Translate to Finnish")
        XCTAssertTrue(prompts.first?.isTextTransformation == true)
        XCTAssertEqual(
            prompts.map(\.promptDescription),
            [
                "Translates document text to the app interface language",
                "Creates a concise summary of the selected text",
                "Explains the meaning and context of selected verses",
                "Create a Study Pad with verse-by-verse explanation and bookmarks",
                "Analyzes original Hebrew/Greek words",
                "Finds and explains related Bible passages",
                "Shows how different installed translations render the text",
                "Builds a StudyPad with passages and notes on the central theme",
                "Creates a bookmark with an AI-generated study note",
                "Opens commentary and parallel translation windows for study",
                "Manage windows: create, close, rearrange, change documents",
                "Improves grammar, clarity, and readability of your note",
                "Ask any question about the selected passage",
                "Run a custom task on the selected passage",
            ]
        )
        XCTAssertEqual(
            prompts.last?.promptTemplate,
            "Follow the user's task specification for the selected Bible passage."
        )
    }

    /**
     Verifies built-ins win over SWORD and user collisions and receive only their v23 model override.

     Setup deliberately seeds all three sources with the same ID. Failure means a synced or add-on
     row could replace immutable app behavior, or a persisted model selection could be ignored.
     */
    func testPromptLookupAppliesBuiltInThenSwordThenUserPrecedenceAndModelOverride() throws {
        let container = try makeAIContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(providerConfigId: provider.id, modelId: "gpt-test")
        try store.insertModel(model)

        let builtIn = AgentPrompt(
            id: BuiltInPromptCatalog.id(forKey: "summary"),
            name: "Built-in",
            promptTemplate: "built-in"
        )
        try store.insertPrompt(
            AgentPrompt(id: builtIn.id, name: "User collision", promptTemplate: "user")
        )
        try store.setBuiltInModelOverride(promptID: builtIn.id, modelID: model.id)
        let packProvider = FixedPromptPackProvider(
            packs: [
                SwordPromptPack(
                    moduleName: "ExamplePack",
                    prompts: [AgentPrompt(id: builtIn.id, name: "Pack collision", promptTemplate: "pack")]
                ),
            ]
        )
        let repository = PromptRepository(
            settingsStore: store,
            packProvider: packProvider,
            builtInPrompts: { [builtIn] }
        )

        let resolved = try XCTUnwrap(repository.entryById(builtIn.id))
        XCTAssertEqual(resolved.origin, .builtIn)
        XCTAssertEqual(resolved.prompt.name, "Built-in")
        XCTAssertEqual(resolved.prompt.configuredModelId, model.id)
    }

    /**
     Verifies effective prompt edits follow source ownership and model override persistence paths.

     Failure means downstream settings UI could mutate code/module prompts, lose user edits, or copy
     a prompt without creating an independent editable identity.
     */
    func testEffectivePromptEditingPreservesSourceOwnershipAndCopiesReadOnlyPrompts() throws {
        let container = try makeAIContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(providerConfigId: provider.id, modelId: "gpt-test")
        try store.insertModel(model)
        let builtIn = AgentPrompt(
            id: BuiltInPromptCatalog.id(forKey: "summary"),
            name: "Built-in",
            promptTemplate: "Summarize"
        )
        let packPrompt = AgentPrompt(
            name: "Pack",
            promptTemplate: "Pack task",
            orderNumber: 3
        )
        let repository = PromptRepository(
            settingsStore: store,
            packProvider: FixedPromptPackProvider(
                packs: [SwordPromptPack(moduleName: "Pack", prompts: [packPrompt])]
            ),
            builtInPrompts: { [builtIn] }
        )
        let user = AgentPrompt(name: "User", promptTemplate: "Original", orderNumber: 5)
        try repository.insert(user)

        let edited = user.detachedCopy(configuredModelId: model.id)
        edited.name = "Edited"
        edited.promptTemplate = "Changed"
        try repository.update(edited)
        XCTAssertEqual(try repository.promptById(user.id)?.name, "Edited")
        XCTAssertEqual(try repository.promptById(user.id)?.configuredModelId, model.id)

        try repository.setConfiguredModel(promptID: builtIn.id, modelID: model.id)
        XCTAssertEqual(try repository.promptById(builtIn.id)?.configuredModelId, model.id)

        let copied = try repository.copy(id: packPrompt.id, name: "Editable copy")
        XCTAssertNotEqual(copied.id, packPrompt.id)
        XCTAssertEqual(copied.name, "Editable copy")
        XCTAssertEqual(copied.orderNumber, 4)
        XCTAssertEqual(user.orderNumber, 6)
        XCTAssertEqual(try repository.entryById(copied.id)?.origin, .user)

        try repository.setBuiltInPromptHidden(true, promptID: builtIn.id)
        XCTAssertFalse(try repository.allPrompts().contains { $0.prompt.id == builtIn.id })
        XCTAssertTrue(
            try repository.allPromptsIncludingHidden().contains { $0.prompt.id == builtIn.id }
        )
        try repository.setFavorite(true, promptID: copied.id)
        XCTAssertTrue(try repository.favoritePromptIDs().contains(copied.id))

        try repository.setConfiguredModel(promptID: packPrompt.id, modelID: model.id)
        XCTAssertEqual(try repository.promptById(packPrompt.id)?.configuredModelId, model.id)
        XCTAssertEqual(
            try repository.allPromptsIncludingHidden().first {
                $0.prompt.id == packPrompt.id
            }?.prompt.configuredModelId,
            model.id
        )
    }

    /**
     Verifies API credentials exist only under Android-compatible secret keys and no registered model
     type can persist them.

     Failure means credentials could enter SwiftData, CloudKit, or backup state, or iOS would use a
     key namespace incompatible with provider lifecycle operations.
     */
    func testCredentialsAreExcludedFromEverySwiftDataRegistration() throws {
        let registeredNames = (AIModelRegistration.cloudSyncableModels
            + AIModelRegistration.localOnlyModels).map { String(describing: $0) }
        XCTAssertFalse(registeredNames.contains { $0.localizedCaseInsensitiveContains("credential") })
        XCTAssertFalse(registeredNames.contains { $0.localizedCaseInsensitiveContains("secret") })
        XCTAssertFalse(registeredNames.contains { $0.localizedCaseInsensitiveContains("apiKey") })
        XCTAssertFalse(
            AIModelRegistration.cloudSyncableModels.contains {
                ObjectIdentifier($0) == ObjectIdentifier(LLMRawLogRecord.self)
            }
        )
        XCTAssertEqual(AIModelRegistration.localOnlyModels.count, 1)
        XCTAssertTrue(
            AIModelRegistration.localOnlyModels.contains {
                ObjectIdentifier($0) == ObjectIdentifier(LLMRawLogRecord.self)
            }
        )

        let secrets = RecordingSecretStore()
        let credentials = AICredentialStore(secretStore: secrets)
        let providerID = UUID(uuidString: "53f3c5a5-579b-43eb-aa1a-d4eceb7dc438")!
        try credentials.setCredential("private-token", for: providerID)

        XCTAssertEqual(
            secrets.values["llm_api_key_53f3c5a5-579b-43eb-aa1a-d4eceb7dc438"],
            "private-token"
        )
        XCTAssertEqual(credentials.credential(for: providerID), "private-token")
    }

    /**
     Verifies explicit AI disclaimer acceptance is durably visible from a fresh SwiftData context.

     The writer and reader share only the container, not managed objects. Failure means the UI could
     advance in memory while a later configuration request or app session still sees the gate.
     */
    func testDisclaimerAcceptancePersistsAcrossModelContexts() throws {
        let container = try makeAIContainer()
        let writerContext = ModelContext(container)
        writerContext.autosaveEnabled = false
        let writer = AISettingsStore(modelContext: writerContext)

        XCTAssertFalse(try writer.globalSettings().aiDisclaimerAccepted)
        try writer.setDisclaimerAccepted(true)

        let readerContext = ModelContext(container)
        readerContext.autosaveEnabled = false
        let reader = AISettingsStore(modelContext: readerContext)
        XCTAssertTrue(try reader.globalSettings().aiDisclaimerAccepted)
    }

    /**
     Verifies a rejected disclaimer save cannot grant transient or later durable acceptance.

     Setup seeds a writable file-backed store, reopens it with `allowsSave: false`, and then reopens
     it writable after the expected permission failure. The test touches only a temporary directory,
     which is removed on exit. Failure means a save error could bypass Android's explicit gate in the
     current context or during a subsequent unrelated save.
     */
    func testDisclaimerAcceptanceRollsBackWhenStoreRejectsSave() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-disclaimer-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("AISettings.store")

        try autoreleasepool {
            let container = try makePersistentAIContainer(at: storeURL, allowsSave: true)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            XCTAssertFalse(
                try AISettingsStore(modelContext: context).globalSettings().aiDisclaimerAccepted
            )
        }

        try autoreleasepool {
            let container = try makePersistentAIContainer(at: storeURL, allowsSave: false)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let store = AISettingsStore(modelContext: context)

            XCTAssertThrowsError(try store.setDisclaimerAccepted(true)) { error in
                let cocoaError = error as NSError
                XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
                XCTAssertEqual(cocoaError.code, NSFileWriteNoPermissionError)
            }
            XCTAssertFalse(try store.globalSettings().aiDisclaimerAccepted)
        }

        try autoreleasepool {
            let container = try makePersistentAIContainer(at: storeURL, allowsSave: true)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            XCTAssertFalse(
                try AISettingsStore(modelContext: context).globalSettings().aiDisclaimerAccepted
            )
        }
    }

    /**
     Verifies a deleted prompt-specific model falls back to the global model and resolves its provider
     and device-only credential.

     Failure means stale synced prompt references would make otherwise configured AI actions unusable.
     */
    func testModelResolverFallsBackFromMissingOverrideToGlobalDefault() throws {
        let container = try makeAIContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .anthropic, displayName: "Anthropic")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(providerConfigId: provider.id, modelId: "claude-test")
        try store.insertModel(model)
        let settings = try store.globalSettings()
        settings.defaultModelId = model.id
        try store.save()

        let secrets = RecordingSecretStore()
        let credentials = AICredentialStore(secretStore: secrets)
        try credentials.setCredential("device-key", for: provider.id)
        let resolver = AIModelResolver(settingsStore: store, credentialStore: credentials)

        let resolved = try resolver.resolve(configuredModelId: UUID())
        XCTAssertEqual(resolved.configuredModelId, model.id)
        XCTAssertEqual(resolved.apiFormat, .anthropic)
        XCTAssertEqual(resolved.endpoint.absoluteString, "https://api.anthropic.com/v1")
        XCTAssertEqual(resolved.credential, "device-key")
        XCTAssertEqual(resolved.supportsCacheControl, false)
        XCTAssertFalse(String(describing: resolved).contains("device-key"))
    }

    /**
     Verifies xAI resolution creates Android's conversation header once without exposing secrets.

     Failure means iterative xAI calls would lose conversation affinity or diagnostics could retain
     a provider credential.
     */
    func testXAIModelResolutionCreatesConversationHeaderWithoutLeakingCredential() throws {
        let container = try makeAIContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .xAI, displayName: "xAI")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(providerConfigId: provider.id, modelId: "grok-test")
        try store.insertModel(model)

        let secrets = RecordingSecretStore()
        let credentials = AICredentialStore(secretStore: secrets)
        try credentials.setCredential("xai-private", for: provider.id)
        let resolved = try AIModelResolver(
            settingsStore: store,
            credentialStore: credentials
        ).resolve(configuredModelId: model.id)

        let conversationID = try XCTUnwrap(resolved.extraHeaders["x-grok-conv-id"])
        XCTAssertNotNil(UUID(uuidString: conversationID))
        XCTAssertFalse(String(describing: resolved).contains("xai-private"))
    }

    /**
     Verifies configured-model deletion clears prompt, default, override, and usage references.

     Failure means a settings edit could leave synced rows pointing at a deleted model.
     */
    func testDeletingConfiguredModelClearsEveryDependentReference() throws {
        let container = try makeAIContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        try store.insertProvider(provider)
        let model = LLMConfiguredModel(providerConfigId: provider.id, modelId: "model")
        try store.insertModel(model)
        let prompt = AgentPrompt(
            name: "User prompt",
            promptTemplate: "Do work",
            configuredModelId: model.id
        )
        try store.insertPrompt(prompt)
        let builtInID = BuiltInPromptCatalog.id(forKey: "summary")
        try store.setBuiltInModelOverride(promptID: builtInID, modelID: model.id)
        let settings = try store.globalSettings()
        settings.defaultModelId = model.id
        try store.save()
        _ = try store.recordUsage(
            LLMUsage(inputTokens: 3, outputTokens: 2),
            configuredModelId: model.id,
            deviceId: "device",
            estimatedCostUSD: 0.01
        )

        try store.deleteModel(id: model.id)

        XCTAssertNil(try store.model(id: model.id))
        XCTAssertNil(prompt.configuredModelId)
        XCTAssertNil(settings.defaultModelId)
        XCTAssertNil(try store.builtInOverride(id: builtInID)?.configuredModelId)
        XCTAssertTrue(try store.usageRecords().isEmpty)
    }

    /**
     Verifies Android semicolon prompt packs preserve quoted multiline templates and typed sets.

     Failure means an installed SWORD prompt pack would silently lose its behavior or tool policy.
     */
    func testPromptPackParserPreservesMultilineTemplateAndTypedBehavior() throws {
        let id = UUID(uuidString: "59d65e07-3427-46a8-9d9d-36bf5a13cb40")!
        let csv = #"""
        id;name;description;promptTemplate;showIn;strictContextMatching;permissionMode;allowedTools;bibleOnly
        \#(id.uuidString);Pack prompt;"From ""module""";"First line
        Second line";VERSE_SELECTION,WINDOW_MENU;false;ASK_ONCE_PER_RUN;GET_VERSE_CONTENT,CREATE_BOOKMARK;true
        """#

        let prompt = try XCTUnwrap(PromptCSVParser.parse(data: Data(csv.utf8)).first)
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.promptDescription, "From \"module\"")
        XCTAssertEqual(prompt.promptTemplate, "First line\nSecond line")
        XCTAssertEqual(prompt.showIn, [.verseSelection, .windowMenu])
        XCTAssertEqual(prompt.showInRawValue, #"["VERSE_SELECTION","WINDOW_MENU"]"#)
        XCTAssertEqual(prompt.allowedTools, [.getVerseContent, .createBookmark])
        XCTAssertEqual(prompt.permissionMode, .askOncePerRun)
        XCTAssertFalse(prompt.strictContextMatching)
        XCTAssertTrue(prompt.bibleOnly)
    }
}

/**
 Builds an in-memory container containing only the AI registration groups.

 The helper performs no disk, CloudKit, or backup writes. Schema construction failures indicate an
 invalid model registration split and are surfaced to each calling test.
 */
@MainActor
private func makeAIContainer() throws -> ModelContainer {
    let models = AIModelRegistration.cloudSyncableModels + AIModelRegistration.localOnlyModels
    let schema = Schema(models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Opens one file-backed AI store with configurable write permission for transaction tests.

 - Parameters:
   - storeURL: Stable SQLite store URL reused across seed, rejection, and verification phases.
   - allowsSave: Whether SwiftData accepts writes through this configuration.
 - Returns: A container containing every production AI model registration.
 - Side effects: Creates or opens the store and its SQLite sidecar files.
 - Throws: Schema, configuration, migration, or persistent-store loading errors.
 */
@MainActor
private func makePersistentAIContainer(
    at storeURL: URL,
    allowsSave: Bool
) throws -> ModelContainer {
    let models = AIModelRegistration.cloudSyncableModels + AIModelRegistration.localOnlyModels
    let schema = Schema(models)
    let configuration = ModelConfiguration(
        "AISettingsBehaviorTests",
        schema: schema,
        url: storeURL,
        allowsSave: allowsSave,
        cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}

/** Deterministic prompt-pack provider used to exercise source precedence without filesystem I/O. */
private final class FixedPromptPackProvider: SwordPromptPackProviding {
    /// Packs returned verbatim in configured order.
    private let packs: [SwordPromptPack]

    /** Creates a provider over fixed parsed packs. */
    init(packs: [SwordPromptPack]) {
        self.packs = packs
    }

    /** Returns configured packs without side effects or failures. */
    func loadPromptPacks() throws -> [SwordPromptPack] {
        packs
    }
}

/**
 In-memory `SecretStoring` double that records exact account keys and values.

 It intentionally omits Keychain protection behavior; production protection is owned and already
 covered by `KeychainSecretStore`. Tests use this double only to prove credential namespace and model
 exclusion behavior.
 */
private final class RecordingSecretStore: SecretStoring {
    /// Exact logical secret values keyed by account name.
    var values: [String: String] = [:]

    /** Returns an in-memory value without side effects. */
    func secret(forKey key: String) -> String? {
        values[key]
    }

    /** Inserts or replaces an in-memory value. */
    func setSecret(_ value: String, forKey key: String) throws {
        values[key] = value
    }

    /** Removes an in-memory value. */
    func removeSecret(forKey key: String) throws {
        values.removeValue(forKey: key)
    }
}
