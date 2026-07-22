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
    /**
     Verifies a remote-only row exposes About without installed-module management actions.

     The test uses no installed inventory or filesystem state. A failure means an installable row
     can offer uninstall/index/unlock operations for a module that is not locally present.
     */
    func testInstallableRemoteRowsExposeAboutOnly() {
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: nil,
            isBeingInstalled: false
        )

        XCTAssertEqual(actions, [.about])
    }

    /**
     Verifies an installed Bible remains removable when a second Bible is present.

     The in-memory inventory models Android's `SwordDocumentFacade.bibles` count. A failure means the
     planner either hides a legal Android delete action or omits ordinary index management.
     */
    func testInstalledRowsExposeAndroidManagementActions() {
        let kjv = installedModule("KJV", category: .bible)
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: kjv,
            isBeingInstalled: false,
            installedModules: [kjv, installedModule("NASB", category: .bible)]
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex])
    }

    /**
     Verifies an encrypted installed row includes Android's shared manager-backed Unlock action.

     Two Bible fixtures keep uninstall legal so the assertion covers the complete ordered action
     set. A failure means encrypted modules cannot request a key or actions drift from Android order.
     */
    func testEncryptedInstalledRowsIncludeUnlock() {
        let kjv = installedModule("KJV", category: .bible, isEncrypted: true)
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: kjv,
            isBeingInstalled: false,
            installedModules: [kjv, installedModule("NASB", category: .bible)]
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex, .unlock])
    }

    /**
     Verifies active installs hide About while retaining legal installed-module management actions.

     The deterministic in-memory state contains two Bibles and touches no shared resources. A
     failure means transient install state changes Android's delete/index policy unexpectedly.
     */
    func testBeingInstalledRowsHideInlineAboutButKeepInstalledManagementParity() {
        let kjv = installedModule("KJV", category: .bible)
        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: kjv,
            isBeingInstalled: true,
            installedModules: [kjv, installedModule("NASB", category: .bible)]
        )

        XCTAssertEqual(actions, [.uninstall, .deleteIndex])
    }

    /**
     Verifies the only installed Bible cannot expose uninstall while index and unlock remain usable.

     The one-Bible inventory directly models Android's `Book.canDelete` guard. A failure means the UI
     can invite removal that the authoritative service must reject, or hides unrelated management.
     */
    func testOnlyInstalledBibleHidesUninstallAction() {
        let kjv = installedModule("KJV", category: .bible, isEncrypted: true)

        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: kjv,
            isBeingInstalled: false,
            installedModules: [kjv]
        )

        XCTAssertEqual(actions, [.about, .deleteIndex, .unlock])
    }

    /**
     Verifies Bible retention does not prevent uninstalling an installed non-Bible module.

     The inventory contains one Bible and one dictionary. A failure means the planner applies the
     last-Bible policy globally instead of matching Android's category-scoped `Book.canDelete` rule.
     */
    func testNonBibleUninstallRemainsAvailableWithOneInstalledBible() {
        let dictionary = installedModule("STRONGS", category: .dictionary)

        let actions = ModuleDownloadRowActionPlanner.availableActions(
            installedModule: dictionary,
            isBeingInstalled: false,
            installedModules: [installedModule("KJV", category: .bible), dictionary]
        )

        XCTAssertEqual(actions, [.about, .uninstall, .deleteIndex])
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
