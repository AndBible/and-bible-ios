import XCTest
@testable import BibleCore
@testable import SwordKit

/** Contract tests for Android's persisted Search translation selection. */
final class SearchSelectionPreferencesTests: XCTestCase {
    /**
     Verifies persisted order, duplicate filtering, uninstall filtering, and primary-first restore.

     Failure means a recreated Search screen can select or order translations differently from
     Android's `Search.loadSelectedTranslations()` contract.
     */
    func testLoadSelectionPreservesAndroidPersistenceSemantics() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(
            .searchSelectedTranslations,
            value: "WEB, KJV,WEB,REMOVED, "
        )
        let preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB"],
                primaryModuleName: "KJV"
            ),
            ["KJV", "WEB"]
        )
    }

    /**
     Verifies an absent or stale selection falls back to the installed current translation.

     Failure means Search can reopen without a usable target even though Android would seed the
     current document.
     */
    func testLoadSelectionFallsBackToInstalledPrimaryModule() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(.searchSelectedTranslations, value: "REMOVED")
        let preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB"],
                primaryModuleName: "WEB"
            ),
            ["WEB"]
        )
    }

    /**
     Verifies save uses Android's ordered comma-separated representation and ignores an empty commit.

     Failure means dialog selection can reorder translations or erase the last valid persisted
     selection in a way Android does not.
     */
    func testSaveSelectionPreservesOrderAndIgnoresEmptyCommit() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        preferences.saveSelection([" WEB ", "KJV", "WEB", ""])
        XCTAssertEqual(settingsStore.getString(.searchSelectedTranslations), "WEB,KJV")

        preferences.saveSelection([])
        XCTAssertEqual(settingsStore.getString(.searchSelectedTranslations), "WEB,KJV")
    }
}

/** Contract tests for Android's separately persisted EPUB Search mode. */
final class SearchModePreferencesTests: XCTestCase {
    /** Round-trips every supported mode using Android `SearchType.name()` values. */
    func testEpubWordModesRoundTripWithAndroidValueSpellings() throws {
        let store = try makeInMemorySettingsStore()
        let preferences = SearchModePreferences(settingsStore: store)

        XCTAssertNil(preferences.epubWordMode())
        XCTAssertEqual(preferences.epubMode(), .fullTextQuery)
        for (mode, rawValue) in [
            (SearchWordMode.allWords, "ALL_WORDS"),
            (.anyWord, "ANY_WORDS"),
            (.phrase, "PHRASE"),
        ] {
            preferences.saveEpubWordMode(mode)
            XCTAssertEqual(store.getString(.epubSearchType), rawValue)
            XCTAssertEqual(preferences.epubWordMode(), mode)
        }

        preferences.saveEpubMode(.fullTextQuery)
        XCTAssertNil(store.getString(AppPreferenceKey.epubSearchType.rawValue))
        XCTAssertEqual(preferences.epubMode(), .fullTextQuery)
    }

    /** Unknown persisted values preserve Android's nullable/unselected mode instead of guessing. */
    func testUnknownEpubWordModeDoesNotSilentlySelectAnotherMode() throws {
        let store = try makeInMemorySettingsStore()
        store.setString(.epubSearchType, value: "REGEX")

        let preferences = SearchModePreferences(settingsStore: store)
        XCTAssertNil(preferences.epubWordMode())
        XCTAssertEqual(preferences.epubMode(), .fullTextQuery)
    }

    /** Shared EPUB compilation reproduces Android's raw FTS5 decorations without Bible analysis. */
    func testEpubCompilerUsesPersistedModeContract() throws {
        XCTAssertEqual(
            try SearchQueryCompiler.compile(
                query: "faith hope",
                epubMode: .allWords,
                languageCode: "en-US"
            ),
            "faith AND hope"
        )
        XCTAssertEqual(
            try SearchQueryCompiler.compile(
                query: "faith hope",
                epubMode: .anyWords,
                languageCode: "de"
            ),
            "faith OR hope"
        )
        XCTAssertEqual(
            try SearchQueryCompiler.compile(
                query: "Häuser hope",
                epubMode: .phrase,
                languageCode: "de"
            ),
            "\"Häuser hope\"",
            "EPUB decoration must not apply the German JSword stemmer"
        )
        XCTAssertEqual(
            try SearchQueryCompiler.compile(
                query: "title : faith*",
                epubMode: .fullTextQuery,
                languageCode: "de"
            ),
            "title : faith*"
        )
        XCTAssertThrowsError(
            try SearchQueryCompiler.compile(
                query: "  ",
                epubMode: .fullTextQuery,
                languageCode: "en"
            )
        ) { error in
            XCTAssertEqual(error as? SearchIndexError, .emptyQuery)
        }
    }
}
