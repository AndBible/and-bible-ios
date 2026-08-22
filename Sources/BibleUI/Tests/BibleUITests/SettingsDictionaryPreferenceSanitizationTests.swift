import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Package-lane coverage for Android-compatible dictionary preference sanitation.

 The settings screen owns this policy because merely opening or refreshing Settings must not turn
 an unavailable explicit dictionary choice into the empty-set automatic-selection state.
 */
final class SettingsDictionaryPreferenceSanitizationTests: XCTestCase {
    /**
     Verifies unavailable explicit dictionary names survive inventory sanitation and persistence.

     - Setup: Persists unavailable Greek, Hebrew, and morphology selections together with one valid
       and one removed disabled word-lookup dictionary.
     - Expected result: All explicit selections remain byte-for-byte present while only the removed
       inverse disabled value is pruned from returned and stored state.
     - Failure meaning: Opening Settings can erase user selection authority and silently reactivate
       automatic Strong's or morphology candidate discovery.
     - Side effects: Writes only to an in-memory SwiftData `SettingsStore`.
     */
    func testSanitationPreservesUnavailableExplicitDictionarySelections() throws {
        let store = try makeInMemorySettingsStore()
        let greek = Set(["UnavailableGreek"])
        let hebrew = Set(["UnavailableHebrew"])
        let morphology = Set(["UnavailableMorphology"])
        let disabledWordLookup = Set(["InstalledWordLookup", "RemovedWordLookup"])
        store.setStringSet(.strongsGreekDictionary, values: Array(greek))
        store.setStringSet(.strongsHebrewDictionary, values: Array(hebrew))
        store.setStringSet(.robinsonGreekMorphology, values: Array(morphology))
        store.setStringSet(
            .disabledWordLookupDictionaries,
            values: Array(disabledWordLookup)
        )

        let sanitized = SettingsView.sanitizeDictionaryPreferences(
            SettingsView.DictionaryPreferenceSanitizationState(
                strongsGreek: Set(store.getStringSet(.strongsGreekDictionary)),
                strongsHebrew: Set(store.getStringSet(.strongsHebrewDictionary)),
                robinsonMorphology: Set(store.getStringSet(.robinsonGreekMorphology)),
                disabledWordLookup: Set(store.getStringSet(.disabledWordLookupDictionaries))
            ),
            availableWordLookupNames: ["InstalledWordLookup"],
            store: store
        )

        XCTAssertEqual(sanitized.strongsGreek, greek)
        XCTAssertEqual(sanitized.strongsHebrew, hebrew)
        XCTAssertEqual(sanitized.robinsonMorphology, morphology)
        XCTAssertEqual(sanitized.disabledWordLookup, ["InstalledWordLookup"])
        XCTAssertEqual(Set(store.getStringSet(.strongsGreekDictionary)), greek)
        XCTAssertEqual(Set(store.getStringSet(.strongsHebrewDictionary)), hebrew)
        XCTAssertEqual(Set(store.getStringSet(.robinsonGreekMorphology)), morphology)
        XCTAssertEqual(
            Set(store.getStringSet(.disabledWordLookupDictionaries)),
            ["InstalledWordLookup"]
        )
    }
}
