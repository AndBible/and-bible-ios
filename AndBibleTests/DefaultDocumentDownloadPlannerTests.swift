// DefaultDocumentDownloadPlannerTests.swift - startup default-document planner coverage

import XCTest
@testable import SwordKit

final class DefaultDocumentDownloadPlannerTests: XCTestCase {
    func testSelectsEnglishDefaultsInAndroidBucketOrder() {
        let configuration = ModuleDownloadConfiguration(
            bibles: ["en": ["KJV::CrossWire"]],
            commentaries: ["en": ["MHC"]],
            dictionaries: ["en": ["StrongsHebrew::CrossWire"]],
            books: ["en": ["Pilgrim"]],
            maps: ["en": ["BibleMap"]],
            addons: ["en": ["UnsupportedAddon"]]
        )
        let availableModules = [
            remoteModule("StrongsHebrew", category: .dictionary, sourceName: "CrossWire"),
            remoteModule("KJV", category: .bible, sourceName: "WrongSource"),
            remoteModule("KJV", category: .bible, sourceName: "CrossWire"),
            remoteModule("BibleMap", category: .map, sourceName: "CrossWire"),
            remoteModule("Pilgrim", category: .generalBook, sourceName: "CrossWire"),
            remoteModule("MHC", category: .commentary, sourceName: "CrossWire"),
            remoteModule("UnsupportedAddon", category: .unknown, sourceName: "AndBible"),
        ]

        let selected = DefaultDocumentDownloadPlanner.selectedModules(
            from: configuration,
            availableModules: availableModules,
            installedModules: []
        )

        XCTAssertEqual(selected.map(\.name), ["KJV", "MHC", "Pilgrim", "StrongsHebrew", "BibleMap"])
        XCTAssertEqual(selected.map(\.sourceName), ["CrossWire", "CrossWire", "CrossWire", "CrossWire", "CrossWire"])
    }

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

    private func installedModule(_ name: String, category: ModuleCategory) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: category,
            language: "en"
        )
    }
}
