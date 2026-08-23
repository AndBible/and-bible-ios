// AIReaderReferenceEnvironmentResolverTests.swift -- AI reference-default parity coverage

import SwiftData
import SwordKit
import XCTest
@testable import BibleCore
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
            excludedInitials: ["ESV2011"],
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
            excludedInitials: ["BDB", "Thayer"],
            indexedModule: { _ in false },
            selectedStrongsHebrew: ["Missing", "BDB", "StrongsHebrew"],
            selectedStrongsGreek: ["Thayer"],
            selectedGreekMorphology: ["robinson"]
        )

        XCTAssertEqual(value.preferredStrongsHebrew, "StrongsHebrew")
        XCTAssertNil(value.preferredStrongsGreek)
        XCTAssertEqual(value.preferredGreekMorphology, "Robinson")
    }

    /** Explicit prompt preferences resolve JSword full-name and case tiers to canonical initials. */
    func testSelectedDictionaryFullNameAliasUsesGlobalJSwordLookup() {
        let modules = [
            module(
                "BDBComplete",
                description: "Hebrew Scholar Lexicon",
                features: [.hebrewDef]
            ),
        ]

        let value = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: modules,
            excludedInitials: [],
            indexedModule: { _ in false },
            selectedStrongsHebrew: ["hebrew scholar lexicon"],
            selectedStrongsGreek: [],
            selectedGreekMorphology: []
        )

        XCTAssertEqual(value.preferredStrongsHebrew, "BDBComplete")
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

    /**
     Keeps AI exclusion persistence, tool authorization, and prompt defaults Java-exact.

     - Setup: Stores composed and decomposed initials in Android's raw JSON array, removes only the
       decomposed spelling like one UI toggle, and builds the production settings policy plus prompt
       environment over both Java-distinct Bible registrations.
     - Expected result: Both spellings survive raw round-trip initially; removing one leaves the
       composed book denied and decomposed book allowed/defaulted by both tool and prompt boundaries.
     - Failure meaning: Swift canonical `Set<String>` semantics can hide a row, toggle two rows at
       once, or make the system prompt advertise a source that Agent tools deny.
     - Side effects: Creates and mutates one in-memory AI settings container only.
     */
    @MainActor
    func testJavaDistinctExclusionsRoundTripAndKeepPromptToolAuthorizationAligned() throws {
        let composed = "Caf\u{00E9}Bible"
        let decomposed = "Cafe\u{0301}Bible"
        XCTAssertFalse(SwordJavaStringIdentity.equals(composed, decomposed))
        let models = AIModelRegistration.cloudSyncableModels + AIModelRegistration.localOnlyModels
        let schema = Schema(models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let store = AISettingsStore(modelContext: container.mainContext)
        let settings = try store.globalSettings()
        settings.aiExcludedDocuments = [decomposed, composed]
        try store.save()

        let rawValues = try JSONDecoder().decode(
            [String].self,
            from: Data(settings.aiExcludedDocumentsRawValue.utf8)
        )
        XCTAssertEqual(rawValues.count, 2)
        XCTAssertTrue(rawValues.contains(where: {
            SwordJavaStringIdentity.equals($0, composed)
        }))
        XCTAssertTrue(rawValues.contains(where: {
            SwordJavaStringIdentity.equals($0, decomposed)
        }))

        var exclusions = settings.aiExcludedDocuments
        XCTAssertTrue(exclusions.remove(decomposed))
        XCTAssertTrue(exclusions.contains(composed))
        XCTAssertFalse(exclusions.contains(decomposed))
        settings.aiExcludedDocuments = exclusions
        try store.save()

        let policy = BibleUIAgentSettingsDocumentAccessPolicy(settingsStore: store)
        XCTAssertFalse(policy.allows(documentInitials: composed))
        XCTAssertTrue(policy.allows(documentInitials: decomposed))
        let environment = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: [
                module(composed, category: .bible),
                module(decomposed, category: .bible),
            ],
            excludedInitials: settings.aiExcludedDocuments,
            indexedModule: { _ in true },
            selectedStrongsHebrew: [],
            selectedStrongsGreek: [],
            selectedGreekMorphology: []
        )
        XCTAssertEqual(environment.defaultSearchBible?.initials, decomposed)
    }

    /** Creates supported metadata sufficient for the pure installed-book selection contract. */
    private func module(
        _ name: String,
        description: String? = nil,
        category: ModuleCategory = .dictionary,
        language: String = "en",
        features: ModuleFeatures = []
    ) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: description ?? name,
            category: category,
            language: language,
            moduleDriver: category == .bible ? "zText" : "zLD",
            features: features,
            aboutMetadata: ModuleAboutMetadata(versification: "KJV")
        )
    }
}
