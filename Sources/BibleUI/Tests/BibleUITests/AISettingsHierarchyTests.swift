import BibleCore
import SwordKit
import XCTest
@testable import BibleUI

/** Android-parity contracts for AI Settings and Connection settings hierarchy. */
final class AISettingsHierarchyTests: XCTestCase {
    /**
     Verifies Android's `llmConfigured` screen discriminator uses provider existence only.

     No model, credential, or default-model fixture is involved because Android switches from the
     Configure AI state to prompt management as soon as one provider row exists. A failure means iOS
     has coupled navigation structure back to stricter execution readiness.
     */
    func testRootModeChangesWhenFirstProviderExists() {
        XCTAssertEqual(AISettingsRootMode.resolve(providerCount: 0), .setup)
        XCTAssertEqual(AISettingsRootMode.resolve(providerCount: 1), .prompts)
        XCTAssertEqual(AISettingsRootMode.resolve(providerCount: 4), .prompts)
    }

    /**
     Verifies Android's zero-provider Connection settings state.

     Quick Setup must be visible while Models, Behavior, Advanced, and Usage remain absent. A failure
     means the initial iOS screen will again expose configuration that Android intentionally hides.
     */
    func testConnectionSettingsWithNoProvidersShowsOnlyGettingStartedRows() {
        XCTAssertEqual(
            AIConnectionSettingsVisibility.resolve(providerCount: 0),
            AIConnectionSettingsVisibility(
                showsQuickSetup: true,
                showsConfiguredSections: false
            )
        )
    }

    /**
     Verifies Android's configured Connection settings state.

     Once any provider exists, Quick Setup disappears and Models, Behavior, Advanced, and Usage all
     become visible together. A failure means iOS has drifted from Android's refresh contract.
     */
    func testConnectionSettingsWithProviderShowsConfiguredSections() {
        XCTAssertEqual(
            AIConnectionSettingsVisibility.resolve(providerCount: 1),
            AIConnectionSettingsVisibility(
                showsQuickSetup: false,
                showsConfiguredSections: true
            )
        )
    }

    /**
     Verifies both protected entry points preserve Android's disclaimer-to-dialog transition.

     A failure means acceptance can resume the wrong action or one of Android's dialog workflows has
     drifted back into a pushed destination.
     */
    func testProtectedConfigurationRequestsResolveToAndroidDialogSequence() {
        XCTAssertEqual(
            AIConfigurationDialog.initial(for: .quickSetup, isDisclaimerAccepted: false),
            .disclaimerAcceptance(.quickSetup)
        )
        XCTAssertEqual(
            AIConfigurationDialog.initial(for: .quickSetup, isDisclaimerAccepted: true),
            .quickSetupProvider
        )
        XCTAssertEqual(
            AIConfigurationDialog.initial(for: .addProvider, isDisclaimerAccepted: false),
            .disclaimerAcceptance(.addProvider)
        )
        XCTAssertEqual(
            AIConfigurationDialog.initial(for: .addProvider, isDisclaimerAccepted: true),
            .providerType
        )
    }

    /**
     Verifies post-acceptance routing cannot cross Quick Setup and Add Provider workflows.

     Android dismisses the acceptance dialog and immediately opens the first dialog belonging to
     the retained action. This test pins that identity-preserving transition.
     */
    func testDisclaimerAcceptanceResumesRequestedAndroidDialog() {
        XCTAssertEqual(
            AIConfigurationDialog.destination(for: .quickSetup),
            .quickSetupProvider
        )
        XCTAssertEqual(
            AIConfigurationDialog.destination(for: .addProvider),
            .providerType
        )
    }

    /**
     Verifies Android's permission editor omits agent-flow structural tools.

     Every ordinary read and write tool must remain represented exactly once across the displayed
     categories, while the four completion/title tools from Android's `structuralTools` set remain
     runtime-only. A failure means iOS exposes controls Android deliberately keeps internal.
     */
    func testConfigurableToolGroupsExcludeOnlyAndroidStructuralTools() {
        let displayedTools = AIPermissionPresentation.categories.flatMap(\.tools)
        let displayedSet = Set(displayedTools)

        XCTAssertEqual(displayedTools.count, displayedSet.count)
        XCTAssertEqual(
            Set(AgentTool.allCases).subtracting(displayedSet),
            AIPermissionPresentation.structuralTools
        )
        XCTAssertTrue(displayedSet.isDisjoint(with: AIPermissionPresentation.structuralTools))
    }

    /**
     Verifies AI document access mirrors Android's unified installed-book registry.

     The fixture combines native SWORD and SQLite-backed documents, including duplicate initials
     and an unsupported map. SWORD registration must win duplicate initials, SQLite documents must
     remain visible, and categories absent from Android's filter screen must be excluded. The test
     performs no module discovery or filesystem I/O.
     */
    func testDocumentAccessInventoryMergesAllAndroidVisibleBackends() {
        let swordBible = ModuleInfo(
            name: "KJV",
            description: "SWORD King James Version",
            category: .bible,
            language: "en"
        )
        let sqliteDuplicate = ModuleInfo(
            name: "KJV",
            description: "SQLite duplicate",
            category: .bible,
            language: "en"
        )
        let sqliteCommentary = ModuleInfo(
            name: "MYCOM",
            description: "SQLite commentary",
            category: .commentary,
            language: "en"
        )
        let unsupportedMap = ModuleInfo(
            name: "MAPS",
            description: "Map module",
            category: .map,
            language: "en"
        )

        let merged = AIDocumentAccessInventory.merge(
            swordModules: [swordBible],
            sqliteModules: [sqliteDuplicate, sqliteCommentary, unsupportedMap]
        )

        XCTAssertEqual(merged.map(\.name), ["KJV", "MYCOM"])
        XCTAssertEqual(merged.first?.description, "SWORD King James Version")
    }
}
