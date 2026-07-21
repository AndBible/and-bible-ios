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
     Protects Android's exact application-preferences reset allowlist.

     The expected values are copied from `SettingsActivity.reset()` rather than inferred from iOS
     storage or UI visibility. A failure means iOS has added or removed reset behavior without a
     corresponding Android contract change.
     */
    func testApplicationPreferencesResetContractMatchesAndroidAllowlist() {
        let expected: [AppPreferenceKey] = [
            .strongsGreekDictionary,
            .strongsHebrewDictionary,
            .robinsonGreekMorphology,
            .disabledWordLookupDictionaries,
            .navigateToVersePref,
            .openLinksInSpecialWindowPref,
            .screenKeepOnPref,
            .autoFullscreenPref,
            .fullScreenHideButtonsPref,
            .hideWindowButtons,
            .hideBibleReferenceOverlay,
            .showActiveWindowIndicator,
            .toolbarButtonActions,
            .disableTwoStepBookmarking,
            .doubleTapToFullscreen,
            .nightModePref3,
            .requestSdcardPermissionPref,
            .showErrorBox,
            .showCalculator,
            .calculatorPin,
            .disableBibleBookmarkModalButtons,
            .disableGenBookmarkModalButtons,
            .monochromeMode,
            .disableAnimations,
            .disableClickToEdit,
            .fontSizeMultiplier,
            .bibleViewSwipeMode,
            .experimentalFeatures,
            .notesContentType,
            .localePref,
            .discreteMode,
        ]

        XCTAssertEqual(AppPreferenceRegistry.applicationPreferencesResetKeys, expected)
        XCTAssertEqual(Set(expected).count, expected.count)
        XCTAssertFalse(expected.contains(.volumeKeysScroll))
        XCTAssertFalse(expected.contains(.bookGridLeftToRight))
        XCTAssertFalse(expected.contains(.bookGridGroupByCategory))
        XCTAssertFalse(expected.contains(.bookGridShowLongName))
        XCTAssertFalse(expected.contains(.bookGridShowProgress))
        XCTAssertFalse(expected.contains(.enableBluetoothPref))
        XCTAssertFalse(expected.contains(.searchSelectedTranslations))
        XCTAssertFalse(expected.contains(.epubSearchType))
    }

    /**
     Verifies Settings reset clears Android's allowlist and preserves explicit non-reset sentinels.

     Setup:
     - uses an in-memory SwiftData `SettingsStore`
     - seeds stored and UserDefaults-backed application preferences away from defaults
     - seeds the global text-display JSON to prove reset scope remains application-only
     - snapshots and restores any pre-existing `UserDefaults` values touched by the reset path

     Failure means reset behavior may diverge from Android by either leaving allowlisted values,
     clearing intentionally preserved preferences, or clearing reader display settings unexpectedly.
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
        settingsStore.setBool(.volumeKeysScroll, value: false)
        settingsStore.setBool(.bookGridLeftToRight, value: true)
        settingsStore.setBool(.bookGridGroupByCategory, value: true)
        settingsStore.setBool(.bookGridShowLongName, value: true)
        settingsStore.setBool(.bookGridShowProgress, value: false)
        settingsStore.setBool(.enableBluetoothPref, value: false)
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
        XCTAssertFalse(settingsStore.getBool(.volumeKeysScroll))
        XCTAssertTrue(settingsStore.getBool(.bookGridLeftToRight))
        XCTAssertTrue(settingsStore.getBool(.bookGridGroupByCategory))
        XCTAssertTrue(settingsStore.getBool(.bookGridShowLongName))
        XCTAssertFalse(settingsStore.getBool(.bookGridShowProgress))
        XCTAssertFalse(settingsStore.getBool(.enableBluetoothPref))
        XCTAssertNotNil(settingsStore.getString(SettingsStore.globalTextDisplaySettingsKey))
    }
}
