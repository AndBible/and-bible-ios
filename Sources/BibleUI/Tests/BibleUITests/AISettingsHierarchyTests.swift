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
     Verifies AI document access preserves the shared admitted-owner order and visibility contract.

     - Setup: Supplies already-admitted native, SQLite-like, local EPUB, locked, missing, and
       unsupported map owner rows in JSword order.
     - Expected: Every Android-visible metadata row remains in order, including locked/local rows;
       missing and unsupported categories are omitted.
     - Failure meaning: The filter UI reintroduces a backend-specific merge that can advertise a
       suppressed book or omit the global owner selected by reader/agent lookup.
     - Side effects: None; the fixture contains metadata values only.
     */
    func testDocumentAccessInventoryProjectsAllAndroidVisibleOwnersInGlobalOrder() {
        let swordBible = ModuleInfo(
            name: "KJV",
            description: "SWORD King James Version",
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
        let epub = ModuleInfo(
            name: "Epub-Study_epub",
            description: "Study EPUB",
            category: .generalBook,
            language: "en",
            moduleDriver: "EpubBook"
        )
        let lockedDictionary = ModuleInfo(
            name: "LockedDict",
            description: "Locked dictionary",
            category: .dictionary,
            language: "en",
            isEncrypted: true
        )

        let visible = AIDocumentAccessInventory.visibleModules(
            from: [
                .installed(info: swordBible, readableSource: nil),
                .installed(info: sqliteCommentary, readableSource: nil),
                .local(epub),
                .installed(info: lockedDictionary, readableSource: nil),
                .missing,
                .local(unsupportedMap),
            ]
        )

        XCTAssertEqual(visible.map(\.name), ["KJV", "MYCOM", "Epub-Study_epub", "LockedDict"])
        XCTAssertEqual(visible.first?.description, "SWORD King James Version")
    }
}
