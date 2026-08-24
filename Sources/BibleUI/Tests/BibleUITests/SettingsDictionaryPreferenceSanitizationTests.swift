import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

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
        let greek = SwordJavaExactStringSet(["UnavailableGreek"])
        let hebrew = SwordJavaExactStringSet(["UnavailableHebrew"])
        let morphology = SwordJavaExactStringSet(["UnavailableMorphology"])
        let disabledWordLookup = SwordJavaExactStringSet(["InstalledWordLookup", "RemovedWordLookup"])
        store.setStringSet(.strongsGreekDictionary, values: greek.values)
        store.setStringSet(.strongsHebrewDictionary, values: hebrew.values)
        store.setStringSet(.robinsonGreekMorphology, values: morphology.values)
        store.setStringSet(
            .disabledWordLookupDictionaries,
            values: disabledWordLookup.values
        )

        let sanitized = SettingsView.sanitizeDictionaryPreferences(
            SettingsView.DictionaryPreferenceSanitizationState(
                strongsGreek: SwordJavaExactStringSet(store.getStringSet(.strongsGreekDictionary)),
                strongsHebrew: SwordJavaExactStringSet(store.getStringSet(.strongsHebrewDictionary)),
                robinsonMorphology: SwordJavaExactStringSet(store.getStringSet(.robinsonGreekMorphology)),
                disabledWordLookup: SwordJavaExactStringSet(
                    store.getStringSet(.disabledWordLookupDictionaries)
                )
            ),
            availableWordLookupNames: ["InstalledWordLookup"],
            store: store
        )

        XCTAssertEqual(sanitized.strongsGreek, greek)
        XCTAssertEqual(sanitized.strongsHebrew, hebrew)
        XCTAssertEqual(sanitized.robinsonMorphology, morphology)
        XCTAssertEqual(sanitized.disabledWordLookup, ["InstalledWordLookup"])
        XCTAssertEqual(
            SwordJavaExactStringSet(store.getStringSet(.strongsGreekDictionary)),
            greek
        )
        XCTAssertEqual(
            SwordJavaExactStringSet(store.getStringSet(.strongsHebrewDictionary)),
            hebrew
        )
        XCTAssertEqual(
            SwordJavaExactStringSet(store.getStringSet(.robinsonGreekMorphology)),
            morphology
        )
        XCTAssertEqual(
            SwordJavaExactStringSet(store.getStringSet(.disabledWordLookupDictionaries)),
            ["InstalledWordLookup"]
        )
    }

    /**
     Verifies dictionary settings retain Java-distinct NFC/NFD and case-variant module identities.

     The persisted inverse set is sanitized against the exact installed inventory and written back
     without schema conversion. The picker projection also removes only the repeated exact NFC row.
     Failure means opening Settings can merge two Android books or render duplicate exact choices.
     */
    func testSanitationRoundTripsJavaExactDictionaryIdentities() throws {
        let store = try makeInMemorySettingsStore()
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let persisted = SwordJavaExactStringSet([composed, decomposed, "FOO", "foo", composed])
        store.setStringSet(.disabledWordLookupDictionaries, values: persisted.values)

        let sanitized = SettingsView.sanitizeDictionaryPreferences(
            SettingsView.DictionaryPreferenceSanitizationState(
                strongsGreek: persisted,
                strongsHebrew: persisted,
                robinsonMorphology: persisted,
                disabledWordLookup: SwordJavaExactStringSet(
                    store.getStringSet(.disabledWordLookupDictionaries)
                )
            ),
            availableWordLookupNames: persisted,
            store: store
        )

        XCTAssertEqual(sanitized.strongsGreek.count, 4)
        XCTAssertEqual(sanitized.strongsHebrew.count, 4)
        XCTAssertEqual(sanitized.robinsonMorphology.count, 4)
        XCTAssertEqual(sanitized.disabledWordLookup.count, 4)
        XCTAssertEqual(
            Set(store.getStringSet(.disabledWordLookupDictionaries).map(
                SwordJavaExactStringIdentity.init
            )).count,
            4
        )

        let rows = SettingsView.javaExactDistinctDictionaryModules([
            dictionary(composed),
            dictionary(decomposed),
            dictionary("FOO"),
            dictionary("foo"),
            dictionary(composed),
        ])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map { SwordJavaExactStringIdentity($0.name) }).count, 4)
    }

    /**
     Creates one metadata-only dictionary row for exact identity sanitation coverage.

     - Parameter name: Exact module initials retained by the fixture.
     - Returns: Installed dictionary metadata without content or filesystem ownership.
     - Side effects: None.
     - Failure modes: None.
     */
    private func dictionary(_ name: String) -> ModuleInfo {
        ModuleInfo(
            name: name,
            description: name,
            category: .dictionary,
            language: "en"
        )
    }
}
