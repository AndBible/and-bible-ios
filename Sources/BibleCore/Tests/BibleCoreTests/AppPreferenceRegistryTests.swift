import Foundation
import XCTest
@testable import BibleCore

/**
 Package-lane coverage for application preference registry and reset contracts.

 These tests keep pure BibleCore preference behavior out of the app-host bundle while preserving the
 Android-backed defaults and reset semantics consumed by settings, backup restore, and startup code.
 */
final class AppPreferenceRegistryTests: XCTestCase {
    /**
     Verifies every `AppPreferenceKey` has exactly one registry definition.

     Failure means a new preference key can be introduced without storage metadata, default handling,
     or reset semantics in the shared BibleCore registry.
     */
    func testAppPreferenceRegistryHasDefinitionForAllKeys() {
        let keys = AppPreferenceKey.allCases
        XCTAssertEqual(keys.count, 40)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(AppPreferenceRegistry.definitions.count, keys.count)

        for key in keys {
            XCTAssertEqual(AppPreferenceRegistry.definition(for: key).key, key)
        }
    }

    /**
     Protects Android-parity defaults for high-impact application settings.

     The values here are durable user-visible contracts rather than arbitrary seed data. A failure
     indicates app startup, settings reset, or Android backup restore may now diverge from Android.
     */
    func testCriticalPreferenceDefaultsMatchParityContract() {
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .nightModePref3), "system")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions), "default")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode), "CHAPTER")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .notesContentType), "HTML")
        XCTAssertEqual(AppPreferenceRegistry.intDefault(for: .fontSizeMultiplier), 100)
        XCTAssertEqual(AppPreferenceRegistry.intRange(for: .fontSizeMultiplier), 10...500)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridLeftToRight), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridGroupByCategory), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridShowLongName), false)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .bookGridShowProgress), true)
    }

    /**
     Verifies note-format normalization accepts only the Android-supported persisted values.

     Setup uses direct normalizer calls because the behavior is pure BibleCore value normalization.
     Failure means imported or manually edited settings may persist unsupported note editor formats.
     */
    func testNotesContentTypeNormalizerUsesAndroidSupportedValues() {
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("HTML"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("MARKDOWN"), "MARKDOWN")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("markdown"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType("PLAINTEXT"), "HTML")
        XCTAssertEqual(AppPreferenceValueNormalizer.notesContentType(""), "HTML")
    }

    /**
     Verifies action-only rows are modeled as commands, not persisted preferences.

     Android exposes these as immediate settings actions. A failure means the shared registry could
     accidentally assign defaults or persisted value types to rows that should never be reset or
     stored.
     */
    func testActionPreferencesUseActionShape() {
        let actionKeys: [AppPreferenceKey] = [
            .discreteHelp,
            .openLinks,
            .crashApp,
        ]

        for key in actionKeys {
            let definition = AppPreferenceRegistry.definition(for: key)
            if case .action = definition.storage {
                // expected
            } else {
                XCTFail("Expected .action storage for \(key.rawValue)")
            }
            if case .action = definition.valueType {
                // expected
            } else {
                XCTFail("Expected .action valueType for \(key.rawValue)")
            }
            XCTAssertNil(definition.defaultValue)
        }
    }

    /**
     Protects the Android application-preferences reset set.

     Resettable visible keys must be present, action rows must be excluded, and duplicate keys must
     not appear. A failure means reset behavior can either skip real preferences or attempt to reset
     command rows that do not own durable state.
     */
    func testApplicationPreferencesResetContractExcludesActionRowsAndIncludesVisibleParityKeys() {
        let resetKeys = AppPreferenceRegistry.applicationPreferencesResetKeys

        XCTAssertTrue(resetKeys.contains(.navigateToVersePref))
        XCTAssertTrue(resetKeys.contains(.volumeKeysScroll))
        XCTAssertTrue(resetKeys.contains(.localePref))
        XCTAssertTrue(resetKeys.contains(.calculatorPin))
        XCTAssertTrue(resetKeys.contains(.experimentalFeatures))
        XCTAssertFalse(resetKeys.contains(.discreteHelp))
        XCTAssertFalse(resetKeys.contains(.openLinks))
        XCTAssertFalse(resetKeys.contains(.crashApp))
        XCTAssertEqual(Set(resetKeys).count, resetKeys.count)
    }

    /**
     Verifies application preference reset restores registry defaults without clearing text display.

     Setup:
     - uses an in-memory SwiftData `SettingsStore`
     - seeds stored and UserDefaults-backed application preferences away from defaults
     - seeds the global text-display JSON to prove reset scope remains application-only
     - snapshots and restores any pre-existing `UserDefaults` values touched by the reset path

     Failure means reset behavior may diverge from Android by either leaving stale application
     values, resetting action rows indirectly, or clearing reader display settings unexpectedly.
     */
    func testSettingsStoreResetApplicationPreferencesRestoresRegistryDefaults() throws {
        let userDefaultsKeys: [AppPreferenceKey] = [.localePref, .showCalculator, .calculatorPin, .discreteMode]
        let savedUserDefaults = Dictionary(
            uniqueKeysWithValues: userDefaultsKeys.compactMap { key in
                UserDefaults.standard.object(forKey: key.rawValue).map { value in
                    (key, value)
                }
            }
        )
        userDefaultsKeys.forEach { UserDefaults.standard.removeObject(forKey: $0.rawValue) }
        defer {
            userDefaultsKeys.forEach { key in
                if let value = savedUserDefaults[key] {
                    UserDefaults.standard.set(value, forKey: key.rawValue)
                } else {
                    UserDefaults.standard.removeObject(forKey: key.rawValue)
                }
            }
        }

        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setBool(.navigateToVersePref, value: true)
        settingsStore.setString(.toolbarButtonActions, value: "swap-menu")
        settingsStore.setString(.notesContentType, value: "MARKDOWN")
        settingsStore.setInt(.fontSizeMultiplier, value: 180)
        settingsStore.setStringSet(.experimentalFeatures, values: ["feature_b", "feature_a"])
        settingsStore.setString(.localePref, value: "fi")
        settingsStore.setBool(.showCalculator, value: true)
        settingsStore.setString(.calculatorPin, value: "9999")
        settingsStore.setBool(.discreteMode, value: true)
        settingsStore.setString(SettingsStore.globalTextDisplaySettingsKey, value: #"{"fontSize":22}"#)

        settingsStore.resetApplicationPreferences()

        XCTAssertEqual(settingsStore.getBool(.navigateToVersePref), false)
        XCTAssertEqual(settingsStore.getString(.toolbarButtonActions), "default")
        XCTAssertEqual(settingsStore.getString(.notesContentType), "HTML")
        XCTAssertEqual(settingsStore.getInt(.fontSizeMultiplier), 100)
        XCTAssertEqual(settingsStore.getStringSet(.experimentalFeatures), [])
        XCTAssertEqual(settingsStore.getString(.localePref), "")
        XCTAssertEqual(settingsStore.getBool(.showCalculator), false)
        XCTAssertEqual(settingsStore.getString(.calculatorPin), "1234")
        XCTAssertEqual(settingsStore.getBool(.discreteMode), false)
        XCTAssertNotNil(settingsStore.getString(SettingsStore.globalTextDisplaySettingsKey))
    }
}
