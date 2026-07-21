// AIReaderReferenceEnvironmentResolverTests.swift -- AI reference-default parity coverage

import SwordKit
import XCTest
@testable import BibleUI

/**
 Verifies prompt-visible AI defaults follow Android's installed-book, preference, index, and
 exclusion rules.

 These tests protect the contract shared by the system message and tool defaults. A failure means an
 agent may be instructed to use a different Bible or dictionary than the runtime will select.
 */
final class AIReaderReferenceEnvironmentResolverTests: XCTestCase {
    /** The first allowed indexed Bible must match the search tool's implicit module selection. */
    func testDefaultSearchBibleSkipsExcludedAndUnindexedModules() {
        let modules = [
            module("KJV", category: .bible, language: "en"),
            module("ESV2011", category: .bible, language: "en"),
            module("LXX", category: .bible, language: "grc"),
        ]

        let value = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: modules,
            excludedInitials: ["esv2011"],
            indexedModule: { ["ESV2011", "LXX"].contains($0) },
            selectedStrongsHebrew: [],
            selectedStrongsGreek: [],
            selectedGreekMorphology: []
        )

        XCTAssertEqual(
            value.defaultSearchBible,
            AIReaderMessageComposer.SearchBible(initials: "LXX", language: "Ancient Greek")
        )
    }

    /** Persisted dictionary order wins, while stale and excluded selections are skipped. */
    func testSelectedDictionaryDefaultsUseFirstInstalledAllowedPreference() {
        let modules = [
            module("BDB", features: [.hebrewDef]),
            module("StrongsHebrew", features: [.hebrewDef]),
            module("Thayer", features: [.greekDef]),
            module("Robinson", features: [.greekParse]),
        ]

        let value = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: modules,
            excludedInitials: ["BDB", "THAYER"],
            indexedModule: { _ in false },
            selectedStrongsHebrew: ["Missing", "BDB", "StrongsHebrew"],
            selectedStrongsGreek: ["Thayer"],
            selectedGreekMorphology: ["robinson"]
        )

        XCTAssertEqual(value.preferredStrongsHebrew, "StrongsHebrew")
        XCTAssertNil(value.preferredStrongsGreek)
        XCTAssertEqual(value.preferredGreekMorphology, "Robinson")
    }

    /** Empty preferences use installed feature order before Android's named placeholder fallback. */
    func testFeatureDefaultsAndPlaceholdersMatchAndroidFacade() {
        let modules = [
            module("GreekLexicon", features: [.greekDef]),
            module("HebrewLexicon", features: [.hebrewDef]),
        ]

        let value = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: modules,
            excludedInitials: ["GreekLexicon", "Robinson"],
            indexedModule: { _ in false },
            selectedStrongsHebrew: [],
            selectedStrongsGreek: [],
            selectedGreekMorphology: []
        )

        XCTAssertEqual(value.preferredStrongsHebrew, "HebrewLexicon")
        XCTAssertEqual(value.preferredStrongsGreek, "StrongsGreek")
        XCTAssertNil(value.preferredGreekMorphology)
    }

    /** Creates supported metadata sufficient for the pure installed-book selection contract. */
    private func module(
        _ name: String,
        category: ModuleCategory = .dictionary,
        language: String = "en",
        features: ModuleFeatures = []
    ) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: category,
            language: language,
            moduleDriver: category == .bible ? "zText" : "zLD",
            features: features,
            aboutMetadata: ModuleAboutMetadata(versification: "KJV")
        )
    }
}
