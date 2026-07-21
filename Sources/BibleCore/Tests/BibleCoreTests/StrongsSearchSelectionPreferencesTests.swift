import XCTest
@testable import BibleCore

/**
 Protects Android's separate persisted translation selections for manual Search and Strong's Find All.

 The suite uses an in-memory `SettingsStore`, so persistence is deterministic and cannot modify app
 settings. Failures mean one Search flow can contaminate the other's module selection or Strong's
 restore can reorder the remembered result document.
 */
final class StrongsSearchSelectionPreferencesTests: XCTestCase {
    /**
     Verifies Strong's restore reads only its own key, filters ineligible names supplied by the
     caller, and preserves remembered order without moving the active Bible first.

     Setup seeds different CSV values under Android's two exact keys. The expected result proves
     normal Search remains primary-first while Find All stays isolated and order-preserving.
     */
    func testStrongsSelectionIsIsolatedFromNormalSearchAndPreservesRememberedOrder() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(.searchSelectedTranslations, value: "PLAIN,KJV")
        settingsStore.setString(.searchResultsStrongsTranslations, value: "WEB,KJV,PLAIN")
        let preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB", "PLAIN"],
                primaryModuleName: "KJV"
            ),
            ["KJV", "PLAIN"]
        )
        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB"],
                primaryModuleName: "KJV",
                context: .strongsFindAll
            ),
            ["WEB", "KJV"]
        )

        preferences.saveSelection(["KJV", "WEB"], context: .strongsFindAll)
        XCTAssertEqual(settingsStore.getString(.searchSelectedTranslations), "PLAIN,KJV")
        XCTAssertEqual(settingsStore.getString(.searchResultsStrongsTranslations), "KJV,WEB")
    }

    /**
     Verifies a stale Strong's preference falls back to the caller-selected eligible Bible and the
     saved result survives reconstruction of the preferences service.

     Reconstructing the service models a later Search launch in the same persisted store. A failure
     means Find All can reopen with no usable target or lose its separate translation order.
     */
    func testStrongsSelectionFallsBackAndSurvivesRelaunch() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(.searchResultsStrongsTranslations, value: "REMOVED")
        var preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB"],
                primaryModuleName: "WEB",
                context: .strongsFindAll
            ),
            ["WEB"]
        )

        preferences.saveSelection(["WEB", "KJV"], context: .strongsFindAll)
        preferences = SearchSelectionPreferences(settingsStore: settingsStore)

        XCTAssertEqual(
            preferences.loadSelection(
                installedModuleNames: ["KJV", "WEB"],
                primaryModuleName: "KJV",
                context: .strongsFindAll
            ),
            ["WEB", "KJV"]
        )
    }
}
