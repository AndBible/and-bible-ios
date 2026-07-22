import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects Android's configured-model identity and first-remaining default promotion at persistence.

 Each test uses an isolated in-memory AI schema and performs no Keychain, CloudKit, filesystem, or
 network work. Failure means model management can leave the global default empty or select a model
 that differs from Android's persisted ordering.
 */
@MainActor
final class AISettingsStoreModelFailoverTests: XCTestCase {
    /**
     Verifies deleting the current default promotes the globally first surviving configured model.

     The expected survivor belongs to another provider and has the lowest `orderNumber`; insertion
     order deliberately differs. Failure means `deleteModel` is using provider scope, insertion
     order, or `nil` instead of Android's first remaining global model.
     */
    func testDeletingDefaultModelPromotesFirstRemainingModel() throws {
        let container = try makeModelFailoverContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let firstProvider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        let secondProvider = LLMProviderConfig(provider: .gemini, displayName: "Gemini")
        try store.insertProvider(firstProvider)
        try store.insertProvider(secondProvider)

        let deletedDefault = LLMConfiguredModel(
            providerConfigId: firstProvider.id,
            modelId: "deleted-default",
            orderNumber: 20
        )
        let laterSurvivor = LLMConfiguredModel(
            providerConfigId: firstProvider.id,
            modelId: "later-survivor",
            orderNumber: 8
        )
        let expectedDefault = LLMConfiguredModel(
            providerConfigId: secondProvider.id,
            modelId: "first-survivor",
            orderNumber: 2
        )
        try store.insertModel(deletedDefault)
        try store.insertModel(laterSurvivor)
        try store.insertModel(expectedDefault)
        let settings = try store.globalSettings()
        settings.defaultModelId = deletedDefault.id
        try store.save()

        try store.deleteModel(id: deletedDefault.id)

        XCTAssertEqual(settings.defaultModelId, expectedDefault.id)
        XCTAssertEqual(try store.allModels().map(\.id), [expectedDefault.id, laterSurvivor.id])
    }

    /**
     Verifies deleting a provider that owns the default promotes the first model outside it.

     Two provider-owned rows are removed together while surviving rows have distinct persisted
     order values. Failure means provider deletion clears the default or chooses a row that is also
     being deleted.
     */
    func testDeletingDefaultProviderPromotesFirstModelFromRemainingProviders() throws {
        let container = try makeModelFailoverContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let deletedProvider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        let survivingProvider = LLMProviderConfig(provider: .anthropic, displayName: "Anthropic")
        try store.insertProvider(deletedProvider)
        try store.insertProvider(survivingProvider)

        let deletedDefault = LLMConfiguredModel(
            providerConfigId: deletedProvider.id,
            modelId: "deleted-default",
            orderNumber: 0
        )
        let deletedSibling = LLMConfiguredModel(
            providerConfigId: deletedProvider.id,
            modelId: "deleted-sibling",
            orderNumber: 1
        )
        let laterSurvivor = LLMConfiguredModel(
            providerConfigId: survivingProvider.id,
            modelId: "later-survivor",
            orderNumber: 9
        )
        let expectedDefault = LLMConfiguredModel(
            providerConfigId: survivingProvider.id,
            modelId: "first-survivor",
            orderNumber: 3
        )
        try store.insertModel(deletedDefault)
        try store.insertModel(deletedSibling)
        try store.insertModel(laterSurvivor)
        try store.insertModel(expectedDefault)
        let settings = try store.globalSettings()
        settings.defaultModelId = deletedDefault.id
        try store.save()

        try store.deleteProvider(id: deletedProvider.id)

        XCTAssertEqual(settings.defaultModelId, expectedDefault.id)
        XCTAssertNil(try store.provider(id: deletedProvider.id))
        XCTAssertEqual(try store.allModels().map(\.id), [expectedDefault.id, laterSurvivor.id])
    }

    /**
     Verifies deleting a non-default model does not disturb the selected global default.

     Failure means routine cleanup can unexpectedly switch models even though Android promotes only
     when the deleted row is the current default.
     */
    func testDeletingNonDefaultModelPreservesCurrentDefault() throws {
        let container = try makeModelFailoverContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let provider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        try store.insertProvider(provider)
        let deletedModel = LLMConfiguredModel(
            providerConfigId: provider.id,
            modelId: "deleted",
            orderNumber: 0
        )
        let selectedModel = LLMConfiguredModel(
            providerConfigId: provider.id,
            modelId: "selected",
            orderNumber: 1
        )
        try store.insertModel(deletedModel)
        try store.insertModel(selectedModel)
        let settings = try store.globalSettings()
        settings.defaultModelId = selectedModel.id
        try store.save()

        try store.deleteModel(id: deletedModel.id)

        XCTAssertEqual(settings.defaultModelId, selectedModel.id)
    }

    /**
     Verifies model insertion enforces Android's provider/model composite uniqueness.

     An identical identifier remains valid under another provider, while a duplicate under the same
     provider must fail before insertion. Failure means iOS can create rows Android's Room schema
     rejects and make later default promotion ambiguous.
     */
    func testInsertModelRejectsDuplicateIdentifierOnlyWithinSameProvider() throws {
        let container = try makeModelFailoverContainer()
        let store = AISettingsStore(modelContext: ModelContext(container))
        let firstProvider = LLMProviderConfig(provider: .openAI, displayName: "OpenAI")
        let secondProvider = LLMProviderConfig(provider: .openRouter, displayName: "OpenRouter")
        try store.insertProvider(firstProvider)
        try store.insertProvider(secondProvider)
        try store.insertModel(
            LLMConfiguredModel(providerConfigId: firstProvider.id, modelId: "shared/model")
        )
        try store.insertModel(
            LLMConfiguredModel(providerConfigId: secondProvider.id, modelId: "shared/model")
        )

        XCTAssertThrowsError(
            try store.insertModel(
                LLMConfiguredModel(providerConfigId: firstProvider.id, modelId: "shared/model")
            )
        ) { error in
            XCTAssertEqual(
                error as? AISettingsStoreError,
                .modelAlreadyExists(providerID: firstProvider.id, modelID: "shared/model")
            )
        }
        XCTAssertEqual(try store.allModels().count, 2)
    }
}

/**
 Builds an isolated in-memory container with every production AI model registration.

 - Returns: A transient SwiftData container suitable for `AISettingsStore` mutation tests.
 - Side effects: Allocates process-local in-memory persistence only.
 - Throws: Schema or model-container initialization errors.
 */
@MainActor
private func makeModelFailoverContainer() throws -> ModelContainer {
    let models = AIModelRegistration.cloudSyncableModels + AIModelRegistration.localOnlyModels
    let schema = Schema(models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}
