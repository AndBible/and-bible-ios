// AppPreferenceRegistry.swift — Android application-preferences parity contract

import Foundation

/**
 * Canonical list of Android "Application preferences" keys targeted for iOS parity.
 *
 * The raw values must stay aligned with Android preference keys because they are used as durable
 * storage identifiers across SwiftData, `UserDefaults`, localization audits, and regression tests.
 */
public enum AppPreferenceKey: String, CaseIterable, Sendable {
    // Dictionaries
    case strongsGreekDictionary = "strongs_greek_dictionary"
    case strongsHebrewDictionary = "strongs_hebrew_dictionary"
    case robinsonGreekMorphology = "robinson_greek_morphology"
    case disabledWordLookupDictionaries = "disabled_word_lookup_dictionaries"

    // Application behavior
    case navigateToVersePref = "navigate_to_verse_pref"
    case openLinksInSpecialWindowPref = "open_links_in_special_window_pref"
    case screenKeepOnPref = "screen_keep_on_pref"
    case doubleTapToFullscreen = "double_tap_to_fullscreen"
    case autoFullscreenPref = "auto_fullscreen_pref"
    case toolbarButtonActions = "toolbar_button_actions"
    case disableTwoStepBookmarking = "disable_two_step_bookmarking"
    case bibleViewSwipeMode = "bible_view_swipe_mode"
    case volumeKeysScroll = "volume_keys_scroll"
    case bookGridLeftToRight = "book_grid_ltr"
    case bookGridGroupByCategory = "book_grid_group_by_category"
    case bookGridShowLongName = "book_grid_show_long_name"
    case bookGridShowProgress = "book_grid_show_progress"

    // Look & feel
    case nightModePref3 = "night_mode_pref3"
    case localePref = "locale_pref"
    case monochromeMode = "monochrome_mode"
    case disableAnimations = "disable_animations"
    case disableClickToEdit = "disable_click_to_edit"
    case notesContentType = "notes_content_type"
    case fontSizeMultiplier = "font_size_multiplier"
    case fullScreenHideButtonsPref = "full_screen_hide_buttons_pref"
    case hideWindowButtons = "hide_window_buttons"
    case hideBibleReferenceOverlay = "hide_bible_reference_overlay"
    case showActiveWindowIndicator = "show_active_window_indicator"
    case disableBibleBookmarkModalButtons = "disable_bible_bookmark_modal_buttons"
    case disableGenBookmarkModalButtons = "disable_gen_bookmark_modal_buttons"

    // Settings for the persecuted
    case discreteHelp = "discrete_help"
    case discreteMode = "discrete_mode"
    case showCalculator = "show_calculator"
    case calculatorPin = "calculator_pin"

    // Advanced
    case experimentalFeatures = "experimental_features"
    case enableBluetoothPref = "enable_bluetooth_pref"
    case requestSdcardPermissionPref = "request_sdcard_permission_pref"
    case showErrorBox = "show_errorbox"
    case openLinks = "open_links"
    case crashApp = "crash_app"
}

/**
 * Declares where a parity preference is persisted on iOS.
 *
 * Routing is centralized here so UI code and services do not need to duplicate storage decisions.
 */
public enum AppPreferenceStorageBackend: Sendable {
    /// Persist the value in `SettingsStore`/SwiftData local storage.
    case swiftData
    /// Persist the value in `UserDefaults`, usually for bootstrap-time reads before SwiftData exists.
    case userDefaults
    /// Do not persist the value; the preference represents an action row rather than durable state.
    case action
}

/**
 * Declares the logical shape of a parity preference value.
 *
 * Consumers use this metadata for default decoding, regression tests, and guardrail tooling.
 */
public enum AppPreferenceValueType: Sendable {
    case bool
    case int
    case string
    case csvStringSet
    case action
}

/**
 * Normalizes Android's notes-content-type list preference before the value reaches UI or bridge
 * consumers.
 *
 * Sync, old builds, or direct storage edits can leave unexpected strings in persistence. Android's
 * contract only supports `HTML` and `MARKDOWN`, and the Vue reader models the value as that closed
 * set. Centralizing the normalizer keeps Settings writes and reader payload emission consistent.
 *
 * - Parameter rawValue: Persisted or incoming notes-content-type value.
 * - Returns: `HTML` or `MARKDOWN`; unknown values fall back to Android's default `HTML`.
 * - Side effects: none.
 * - Failure modes: This helper cannot fail.
 */
public enum AppPreferenceValueNormalizer {
    /**
     Normalizes persisted notes-content format values to Android's supported list preference values.
     *
     - Parameter rawValue: Raw value read from persistence or sync.
     - Returns: `HTML` or `MARKDOWN`, falling back to `HTML` for invalid values.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public static func notesContentType(_ rawValue: String) -> String {
        switch rawValue {
        case "HTML", "MARKDOWN":
            return rawValue
        default:
            return "HTML"
        }
    }

    /**
     Validates an optional Android note-row `TextContentType` value without applying app defaults.
     *
     Row-level note content types are nullable on Android. `nil` means "inherit the current app
     preference", while non-null values are read through `TextContentType.valueOf` and therefore must
     be exactly `HTML` or `MARKDOWN`. This helper preserves that distinction for local models and
     sync snapshots so corrupt row values do not silently become HTML.
     *
     - Parameter rawValue: Raw nullable row value from SwiftData, bridge payloads, or sync staging.
     - Returns: `nil`, `HTML`, or `MARKDOWN`; invalid non-null values are returned as `nil`.
     - Side effects: none.
     - Failure modes: This helper cannot fail; callers that need Android-import strictness should
       check `isValidNotesContentTypeRow(_:)` first and throw a parse error for invalid values.
     */
    public static func notesContentTypeRow(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        switch rawValue {
        case "HTML", "MARKDOWN":
            return rawValue
        default:
            return nil
        }
    }

    /**
     Checks whether an optional note-row `TextContentType` is representable by Android.
     *
     - Parameter rawValue: Raw nullable row value from a staged or local note table.
     - Returns: `true` for `nil`, `HTML`, and `MARKDOWN`; `false` for any other non-null string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public static func isValidNotesContentTypeRow(_ rawValue: String?) -> Bool {
        rawValue == nil || notesContentTypeRow(rawValue) != nil
    }
}

/**
 * Defines the full iOS-side contract for one Android parity preference key.
 *
 * Each definition records the durable key, storage backend, logical value type, optional default,
 * optional integer value domain, and the Android source reference used during parity review.
 */
public struct AppPreferenceDefinition: Sendable {
    /// Durable preference key shared with Android parity tracking.
    public let key: AppPreferenceKey
    /// Storage backend that should handle reads and writes for this key.
    public let storage: AppPreferenceStorageBackend
    /// Logical value type used for decoding and regression assertions.
    public let valueType: AppPreferenceValueType
    /// Default raw value used when no persisted value exists.
    public let defaultValue: String?
    /// Android-supported integer range for bounded numeric preferences.
    public let intRange: ClosedRange<Int>?
    /// Android source reference proving the contract origin for this key.
    public let androidReference: String

    /// Creates a parity preference definition.
    public init(
        key: AppPreferenceKey,
        storage: AppPreferenceStorageBackend,
        valueType: AppPreferenceValueType,
        defaultValue: String?,
        intRange: ClosedRange<Int>? = nil,
        androidReference: String
    ) {
        self.key = key
        self.storage = storage
        self.valueType = valueType
        self.defaultValue = defaultValue
        self.intRange = intRange
        self.androidReference = androidReference
    }
}

/**
 * Registry for Android parity keys, types, defaults, and storage backend routing.
 *
 * This registry is the single source of truth for:
 * - which Android application-preference keys iOS has committed to mirror
 * - where each key is stored
 * - how each key is typed and defaulted
 * - which Android source file/line range justified the contract
 *
 * It has no runtime side effects by itself, but downstream code treats its contents as
 * authoritative. Missing definitions are fatal because partial registries would silently break
 * parity reads, settings UI, and regression tooling.
 */
public enum AppPreferenceRegistry {
    /// In-memory lookup table keyed by the durable Android preference identifier.
    private static let definitionMap: [AppPreferenceKey: AppPreferenceDefinition] = [
        .strongsGreekDictionary: .init(
            key: .strongsGreekDictionary,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil, // Runtime default: all available modules.
            androidReference: "settings.xml:28-32, SettingsActivity.kt:183-196"
        ),
        .strongsHebrewDictionary: .init(
            key: .strongsHebrewDictionary,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil, // Runtime default: all available modules.
            androidReference: "settings.xml:33-37, SettingsActivity.kt:183-196"
        ),
        .robinsonGreekMorphology: .init(
            key: .robinsonGreekMorphology,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil, // Runtime default: all available modules.
            androidReference: "settings.xml:38-42, SettingsActivity.kt:183-196"
        ),
        .disabledWordLookupDictionaries: .init(
            key: .disabledWordLookupDictionaries,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil,
            androidReference: "settings.xml:43-47"
        ),
        .navigateToVersePref: .init(
            key: .navigateToVersePref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:55"
        ),
        .openLinksInSpecialWindowPref: .init(
            key: .openLinksInSpecialWindowPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:62"
        ),
        .screenKeepOnPref: .init(
            key: .screenKeepOnPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:67"
        ),
        .doubleTapToFullscreen: .init(
            key: .doubleTapToFullscreen,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:73"
        ),
        .autoFullscreenPref: .init(
            key: .autoFullscreenPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:79"
        ),
        .toolbarButtonActions: .init(
            key: .toolbarButtonActions,
            storage: .swiftData,
            valueType: .string,
            defaultValue: "default",
            androidReference: "settings.xml:81-86"
        ),
        .disableTwoStepBookmarking: .init(
            key: .disableTwoStepBookmarking,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:91"
        ),
        .bibleViewSwipeMode: .init(
            key: .bibleViewSwipeMode,
            storage: .swiftData,
            valueType: .string,
            defaultValue: "CHAPTER",
            androidReference: "settings.xml:100"
        ),
        .volumeKeysScroll: .init(
            key: .volumeKeysScroll,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:104"
        ),
        .bookGridLeftToRight: .init(
            key: .bookGridLeftToRight,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "GridChoosePassageBook.kt:147,192-200,349"
        ),
        .bookGridGroupByCategory: .init(
            key: .bookGridGroupByCategory,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "GridChoosePassageBook.kt:148,203-212,350"
        ),
        .bookGridShowLongName: .init(
            key: .bookGridShowLongName,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "GridChoosePassageBook.kt:149,215-221,351"
        ),
        .bookGridShowProgress: .init(
            key: .bookGridShowProgress,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "GridChoosePassageBook.kt:95-100,171,224-230,352"
        ),
        .nightModePref3: .init(
            key: .nightModePref3,
            storage: .swiftData,
            valueType: .string,
            // Android settings runtime changes default to "system"
            // (SettingsActivity.kt:225-234), even though XML default is "manual".
            defaultValue: "system",
            androidReference: "settings.xml:113"
        ),
        .localePref: .init(
            key: .localePref,
            storage: .userDefaults,
            valueType: .string,
            defaultValue: "",
            androidReference: "settings.xml:124"
        ),
        .monochromeMode: .init(
            key: .monochromeMode,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:128"
        ),
        .disableAnimations: .init(
            key: .disableAnimations,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:134"
        ),
        .disableClickToEdit: .init(
            key: .disableClickToEdit,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:132-137"
        ),
        .notesContentType: .init(
            key: .notesContentType,
            storage: .swiftData,
            valueType: .string,
            defaultValue: "HTML",
            androidReference: "settings.xml:138-145, arrays.xml:264-271"
        ),
        .fontSizeMultiplier: .init(
            key: .fontSizeMultiplier,
            storage: .swiftData,
            valueType: .int,
            defaultValue: "100",
            intRange: 10...500,
            androidReference: "settings.xml:146-153"
        ),
        .fullScreenHideButtonsPref: .init(
            key: .fullScreenHideButtonsPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:156"
        ),
        .hideWindowButtons: .init(
            key: .hideWindowButtons,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:162"
        ),
        .hideBibleReferenceOverlay: .init(
            key: .hideBibleReferenceOverlay,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:168"
        ),
        .showActiveWindowIndicator: .init(
            key: .showActiveWindowIndicator,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:174"
        ),
        .disableBibleBookmarkModalButtons: .init(
            key: .disableBibleBookmarkModalButtons,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil,
            androidReference: "settings.xml:180-186"
        ),
        .disableGenBookmarkModalButtons: .init(
            key: .disableGenBookmarkModalButtons,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil,
            androidReference: "settings.xml:190-196"
        ),
        .discreteHelp: .init(
            key: .discreteHelp,
            storage: .action,
            valueType: .action,
            defaultValue: nil,
            androidReference: "settings.xml:199"
        ),
        .discreteMode: .init(
            key: .discreteMode,
            storage: .userDefaults,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:202"
        ),
        .showCalculator: .init(
            key: .showCalculator,
            storage: .userDefaults,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:207"
        ),
        .calculatorPin: .init(
            key: .calculatorPin,
            storage: .userDefaults,
            valueType: .string,
            defaultValue: "1234",
            androidReference: "settings.xml:213"
        ),
        .experimentalFeatures: .init(
            key: .experimentalFeatures,
            storage: .swiftData,
            valueType: .csvStringSet,
            defaultValue: nil,
            androidReference: "settings.xml:223"
        ),
        .enableBluetoothPref: .init(
            key: .enableBluetoothPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "true",
            androidReference: "settings.xml:230"
        ),
        .requestSdcardPermissionPref: .init(
            key: .requestSdcardPermissionPref,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:234"
        ),
        .showErrorBox: .init(
            key: .showErrorBox,
            storage: .swiftData,
            valueType: .bool,
            defaultValue: "false",
            androidReference: "settings.xml:238"
        ),
        .openLinks: .init(
            key: .openLinks,
            storage: .action,
            valueType: .action,
            defaultValue: nil,
            androidReference: "settings.xml:244"
        ),
        .crashApp: .init(
            key: .crashApp,
            storage: .action,
            valueType: .action,
            defaultValue: nil,
            androidReference: "settings.xml:250"
        ),
    ]

    /**
     * Returns every registered parity definition in the same order as `AppPreferenceKey.allCases`.
     *
     * - Returns: Full registry contents for UI generation, tests, and audit scripts.
     * - Note: Missing entries are filtered out here, but `definition(for:)` still treats them as fatal.
     */
    public static var definitions: [AppPreferenceDefinition] {
        AppPreferenceKey.allCases.compactMap { definitionMap[$0] }
    }

    /**
     * Returns the durable application-preference keys cleared by Android's reset action.
     *
     * The reset contract is derived from storage metadata rather than from the Settings UI so it
     * stays stable when rows move between reader navigation, feature shortcuts, and platform-only
     * presentation surfaces. Action rows are excluded because they do not represent persisted
     * user choices.
     *
     * - Returns: Registered non-action preference keys in `AppPreferenceKey.allCases` order.
     * - Side Effects: None.
     * - Failure: Missing registry entries are filtered by `definitions`; completeness remains
     *   enforced by `definition(for:)` and registry tests.
     */
    public static var applicationPreferencesResetKeys: [AppPreferenceKey] {
        definitions
            .filter { $0.storage != .action }
            .map(\.key)
    }

    /**
     * Returns the registry definition for a single parity key.
     * - Parameter key: Android parity preference key.
     * - Returns: The corresponding definition.
     * - Failure: Triggers `fatalError` if the registry is incomplete for the requested key.
     * - Important: Callers rely on this being exhaustive; do not replace the fatal failure with a silent fallback.
     */
    public static func definition(for key: AppPreferenceKey) -> AppPreferenceDefinition {
        guard let definition = definitionMap[key] else {
            fatalError("Missing app preference definition for key: \(key.rawValue)")
        }
        return definition
    }

    /**
     * Decodes a registry default into a boolean when the key declares one.
     * - Parameter key: Android parity preference key.
     * - Returns: Boolean default for the key, or `nil` when the key has no default.
     */
    public static func boolDefault(for key: AppPreferenceKey) -> Bool? {
        guard let value = definition(for: key).defaultValue else { return nil }
        return value == "true"
    }

    /**
     * Decodes a registry default into an integer when the key declares one.
     * - Parameter key: Android parity preference key.
     * - Returns: Integer default for the key, or `nil` when the key has no default or the raw default is malformed.
     */
    public static func intDefault(for key: AppPreferenceKey) -> Int? {
        guard let value = definition(for: key).defaultValue else { return nil }
        return Int(value)
    }

    /**
     * Returns the Android-supported integer domain for a bounded parity preference.
     * - Parameter key: Android parity preference key.
     * - Returns: Closed integer range for bounded integer preferences, or `nil` for unbounded or
     *   non-integer preferences.
     */
    public static func intRange(for key: AppPreferenceKey) -> ClosedRange<Int>? {
        definition(for: key).intRange
    }

    /**
     * Returns the raw string default declared for a parity key.
     * - Parameter key: Android parity preference key.
     * - Returns: Raw default string, or `nil` when the key has no default.
     */
    public static func stringDefault(for key: AppPreferenceKey) -> String? {
        definition(for: key).defaultValue
    }

    /**
     * Decodes a CSV-backed preference payload into a trimmed string array.
     * - Parameter stored: Raw persisted CSV string, or `nil`.
     * - Returns: Non-empty trimmed members in their stored order.
     * - Failure: `nil`, empty strings, and empty CSV members decode as an empty array.
     */
    public static func decodeCSVSet(_ stored: String?) -> [String] {
        guard let stored, !stored.isEmpty else { return [] }
        return stored
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /**
     * Encodes a string collection into the normalized CSV format used by SwiftData parity settings.
     * - Parameter values: Raw values to persist.
     * - Returns: Sorted, comma-delimited, trimmed values with empty members removed.
     * - Note: This function does not deduplicate by itself. Callers that require set semantics should pass de-duplicated input.
     */
    public static func encodeCSVSet(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }
}
