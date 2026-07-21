import BibleCore
@testable import BibleUI
import XCTest

/** Pure AI settings readiness and usage-accounting behavior coverage. */
final class AIConfigurationUsabilityTests: XCTestCase {
    /**
     Verifies a provider row cannot report usable until both secret and model prerequisites exist.

     Four snapshots isolate the two required inputs. Only the snapshot containing a device-local
     credential and at least one configured model may pass. A regression would expose AI actions
     that can only fail later during model resolution. The test performs no persistence or Keychain I/O.
     */
    func testProviderRequiresCredentialAndConfiguredModel() {
        let providerID = UUID()
        let modelID = UUID()

        XCTAssertFalse(
            AIConfigurationUsability.providerIsUsable(
                .init(providerID: providerID, hasCredential: false, modelIDs: [])
            )
        )
        XCTAssertFalse(
            AIConfigurationUsability.providerIsUsable(
                .init(providerID: providerID, hasCredential: true, modelIDs: [])
            )
        )
        XCTAssertFalse(
            AIConfigurationUsability.providerIsUsable(
                .init(providerID: providerID, hasCredential: false, modelIDs: [modelID])
            )
        )
        XCTAssertTrue(
            AIConfigurationUsability.providerIsUsable(
                .init(providerID: providerID, hasCredential: true, modelIDs: [modelID])
            )
        )
    }

    /**
     Verifies global readiness requires the default model to belong to a usable provider.

     The fixture includes one usable and one credential-free provider. Missing, stale, and
     credential-free defaults must fail while the usable provider's model succeeds. The test is
     deterministic and has no persistence, credential, or network side effects.
     */
    func testDefaultModelMustBelongToUsableProvider() {
        let usableModelID = UUID()
        let unusableModelID = UUID()
        let providers = [
            AIProviderUsabilitySnapshot(
                providerID: UUID(),
                hasCredential: true,
                modelIDs: [usableModelID]
            ),
            AIProviderUsabilitySnapshot(
                providerID: UUID(),
                hasCredential: false,
                modelIDs: [unusableModelID]
            ),
        ]

        XCTAssertFalse(AIConfigurationUsability.defaultModelIsUsable(defaultModelID: nil, providers: providers))
        XCTAssertFalse(AIConfigurationUsability.defaultModelIsUsable(defaultModelID: UUID(), providers: providers))
        XCTAssertFalse(AIConfigurationUsability.defaultModelIsUsable(defaultModelID: unusableModelID, providers: providers))
        XCTAssertTrue(AIConfigurationUsability.defaultModelIsUsable(defaultModelID: usableModelID, providers: providers))
    }

    /**
     Locks current-stable quick setup model IDs and verifies all four token classes affect cost.

     The expected catalog order matches Android's chooser. The cost fixture uses one million tokens
     in each category so its expected value is the direct sum of configured prices. No network,
     Keychain, or persistence work occurs.
     */
    func testRecommendedSetupAndUsagePricingMatchAndroid() {
        XCTAssertEqual(
            AIRecommendedSetupCatalog.options.map(\.modelID),
            ["gemini-3-flash-preview", "claude-haiku-4-5", "gpt-5.4-mini"]
        )
        XCTAssertEqual(
            AIUsageCostCalculator.estimatedCostUSD(
                usage: LLMUsage(
                    inputTokens: 1_000_000,
                    outputTokens: 1_000_000,
                    cacheCreationTokens: 1_000_000,
                    cacheReadTokens: 1_000_000
                ),
                inputPricePerMillion: 1,
                outputPricePerMillion: 2,
                cacheCreationPricePerMillion: 3,
                cacheReadPricePerMillion: 4
            ),
            10,
            accuracy: 0.000_001
        )
    }
}
