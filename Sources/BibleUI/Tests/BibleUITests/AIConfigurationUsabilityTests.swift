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
     Verifies Quick Setup and Add Provider share Android's persisted acceptance gate.

     Each unaccepted request must retain its exact destination through the acceptance dialog, while
     accepted requests proceed immediately. The pure test performs no SwiftData or UI work.
     */
    func testConfigurationActionsRequireExplicitDisclaimerAcceptance() {
        for request in [AIConfigurationEntryRequest.quickSetup, .addProvider] {
            XCTAssertEqual(
                AIDisclaimerGate.decision(for: request, isAccepted: false),
                .requireAcceptance(request)
            )
            XCTAssertEqual(
                AIDisclaimerGate.decision(for: request, isAccepted: true),
                .proceed(request)
            )
        }
    }

    /**
     Verifies the disclaimer follows Android's prose, bullet, privacy, cost, and Scripture order.

     Sentinel copy isolates composition from localization. The assertion catches reintroducing nine
     uniform bullets or moving the Scripture reminder ahead of Android's explanatory paragraphs.
     */
    func testDisclaimerCompositionMatchesAndroidOrderAndStyles() {
        let copy = AIDisclaimerCopy(
            intro: "intro",
            approach: "approach",
            responsibility: "responsibility",
            point1: "p1",
            point2: "p2",
            point3: "p3",
            point4: "p4",
            point5: "p5",
            point6: "p6",
            point7: "p7",
            point8: "p8",
            point9: "p9"
        )

        XCTAssertEqual(
            copy.segments,
            [
                AIDisclaimerSegment(style: .body, text: "intro approach responsibility"),
                AIDisclaimerSegment(style: .bullet, text: "p1"),
                AIDisclaimerSegment(style: .bullet, text: "p2"),
                AIDisclaimerSegment(style: .bullet, text: "p3"),
                AIDisclaimerSegment(style: .bullet, text: "p4"),
                AIDisclaimerSegment(style: .body, text: "p6"),
                AIDisclaimerSegment(style: .body, text: "p7 p8"),
                AIDisclaimerSegment(style: .body, text: "p9"),
                AIDisclaimerSegment(style: .italic, text: "p5"),
            ]
        )
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
