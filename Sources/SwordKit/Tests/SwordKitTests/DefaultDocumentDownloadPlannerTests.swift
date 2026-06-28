// DefaultDocumentDownloadPlannerTests.swift - startup default-document planner coverage

import XCTest
@testable import SwordKit

/**
 Verifies the SwordKit startup document planner without requiring the app host.

 These tests protect Android startup-download parity: fixture rows simulate the
 remote catalog, installed modules, and recommended-document metadata that the
 app receives before it decides which default modules should be queued.
 Failures indicate a user-visible startup download ordering or filtering
 regression, not merely a package-test wiring issue. The suite has no
 filesystem, simulator state, or persisted preference side effects.
 */
final class DefaultDocumentDownloadPlannerTests: XCTestCase {
    /**
     Confirms Android bucket ordering across recommended module categories.

     The fixture includes every supported default bucket plus duplicate module
     names from different repositories. The selected order must remain bible,
     commentary, addon, book, dictionary, map so iOS presents the same initial
     install set Android users receive.
     */
    func testSelectsEnglishDefaultsInAndroidBucketOrder() {
        let configuration = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV::CrossWire"]],
            commentaries: ["en": ["MHC"]],
            dictionaries: ["en": ["StrongsHebrew::CrossWire"]],
            books: ["en": ["Pilgrim"]],
            maps: ["en": ["BibleMap"]],
            addons: ["en": ["AddonFonts"]]
        )
        let availableModules = [
            remoteModule("StrongsHebrew", category: .dictionary, sourceName: "CrossWire"),
            remoteModule("KJV", category: .bible, sourceName: "WrongSource"),
            remoteModule("KJV", category: .bible, sourceName: "CrossWire"),
            remoteModule("BibleMap", category: .map, sourceName: "CrossWire"),
            remoteModule("Pilgrim", category: .generalBook, sourceName: "CrossWire"),
            remoteModule("MHC", category: .commentary, sourceName: "CrossWire"),
            remoteModule("AddonFonts", category: .addon, sourceName: "AndBible"),
        ]

        let selected = DefaultDocumentDownloadPlanner.selectedModules(
            from: configuration,
            availableModules: availableModules,
            installedModules: []
        )

        XCTAssertEqual(selected.map(\.name), ["KJV", "MHC", "AddonFonts", "Pilgrim", "StrongsHebrew", "BibleMap"])
        XCTAssertEqual(
            selected.map(\.sourceName),
            ["CrossWire", "CrossWire", "AndBible", "CrossWire", "CrossWire", "CrossWire"]
        )
    }

    /**
     Ensures unavailable, already installed, missing, and duplicate defaults do not get queued.

     A failure means startup downloads may retry modules the user already has
     or surface catalog entries Android would skip as unavailable/missing.
     */
    func testSkipsInstalledUnavailableMissingAndDuplicateDefaults() {
        let configuration = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV", "KJV", "MissingBible"]],
            commentaries: ["en": ["MHC"]],
            dictionaries: ["en": ["StrongsHebrew"]]
        )
        let availableModules = [
            remoteModule("KJV", category: .bible, sourceName: "CrossWire"),
            remoteModule("MHC", category: .commentary, sourceName: "CrossWire", availability: .unavailable),
            remoteModule("StrongsHebrew", category: .dictionary, sourceName: "CrossWire"),
        ]
        let installedModules = [
            installedModule("KJV", category: .bible),
        ]

        let selected = DefaultDocumentDownloadPlanner.selectedModules(
            from: configuration,
            availableModules: availableModules,
            installedModules: installedModules
        )

        XCTAssertEqual(selected.map(\.name), ["StrongsHebrew"])
    }

    /**
     Preserves Android's first-visible-catalog-row behavior for unscoped defaults.

     The setup intentionally provides the same module from multiple sources;
     unscoped tokens should bind to the first matching visible row so fallback
     behavior is deterministic.
     */
    func testUnscopedTokenUsesFirstMatchingCatalogRow() {
        let configuration = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV"]]
        )
        let availableModules = [
            remoteModule("KJV", category: .bible, sourceName: "CrossWire"),
            remoteModule("KJV", category: .bible, sourceName: "AndBible"),
        ]

        let selected = DefaultDocumentDownloadPlanner.selectedModules(
            from: configuration,
            availableModules: availableModules,
            installedModules: []
        )

        XCTAssertEqual(selected.map(\.sourceName), ["CrossWire"])
    }

    /**
     Ensures source-scoped defaults can still select rows hidden by visible-row deduplication.

     Android recommendations may include repository-qualified tokens. The
     planner must search the full catalog so a deduplicated picker row does not
     silently point users at the wrong repository.
     */
    func testSourceScopedTokenUsesFullCatalogWhenVisibleRowsAreDeduplicated() {
        let configuration = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV::CrossWire"]]
        )
        let fullCatalog = [
            remoteModule("KJV", category: .bible, sourceName: "AndBible"),
            remoteModule("KJV", category: .bible, sourceName: "CrossWire"),
        ]

        let selected = DefaultDocumentDownloadPlanner.selectedModules(
            from: configuration,
            availableModules: fullCatalog,
            installedModules: []
        )

        XCTAssertEqual(selected.map(\.sourceName), ["CrossWire"])
    }

    /**
     Creates a remote catalog fixture with only the fields the planner consumes.

     The helper is deterministic and has no side effects; keeping the fixture
     local avoids pulling app-level download state into SwordKit package tests.
     */
    private func remoteModule(
        _ name: String,
        category: ModuleCategory,
        sourceName: String,
        availability: RemoteModuleAvailability = .installable
    ) -> RemoteModuleInfo {
        RemoteModuleInfo(
            name: name,
            description: name,
            category: category,
            language: "en",
            sourceName: sourceName,
            availability: availability
        )
    }

    /**
     Creates an installed-module fixture used to prove startup defaults skip owned modules.

     The returned value is an in-memory model only; no SWORD module files or
     database rows are created.
     */
    private func installedModule(_ name: String, category: ModuleCategory) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: category,
            language: "en"
        )
    }
}

/**
 Verifies Android-compatible module-row actions without entering Downloads UI.

 These package tests protect the action contract consumed by iOS download and
 module-picker screens. Failures indicate that installed, encrypted, or
 actively installing module rows will expose actions that drift from Android's
 management behavior. The suite mutates no shared state and uses only
 in-memory `ModuleInfo` fixtures.
 */
final class ModuleDownloadRowActionPlannerTests: XCTestCase {
    /// Installable remote-only rows should only expose the about action.
    func testInstallableRemoteRowsExposeAboutOnly() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: nil,
            isBeingInstalled: false
        )

        XCTAssertEqual(actions, [.about])
    }

    /// Installed rows should expose the Android management actions: about, uninstall, and delete index.
    func testInstalledRowsExposeAndroidManagementActions() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule("KJV", category: .bible),
            isBeingInstalled: false
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex])
    }

    /// Encrypted installed rows include unlock only when a cipher coordinator exists.
    func testEncryptedInstalledRowsIncludeUnlockWhenCipherCoordinatorIsSupported() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule("KJV", category: .bible, isEncrypted: true),
            isBeingInstalled: false,
            supportsUnlock: true
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex, .unlock])
    }

    /**
     Documents the current iOS unlock gap so encrypted rows do not expose a dead unlock command.

     Android supports unlock through its cipher flow. Until iOS has an
     equivalent coordinator, the default action list must stay limited to
     actions that actually work.
     */
    func testEncryptedInstalledRowsDocumentIOSUnlockGapByDefault() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule("KJV", category: .bible, isEncrypted: true),
            isBeingInstalled: false
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex])
    }

    /// Active install rows hide inline about while retaining installed-module management parity.
    func testBeingInstalledRowsHideInlineAboutButKeepInstalledManagementParity() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: installedModule("KJV", category: .bible),
            isBeingInstalled: true
        )

        XCTAssertEqual(actions, [.uninstall, .deleteIndex])
    }

    /**
     Creates an installed module fixture for row-action planning tests.

     Encryption flags are modeled in memory only; the helper does not create
     module files, keys, indexes, or database records.
     */
    private func installedModule(
        _ name: String,
        category: ModuleCategory,
        isEncrypted: Bool = false
    ) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: category,
            language: "en",
            isEncrypted: isEncrypted,
            isUnlocked: !isEncrypted
        )
    }
}
