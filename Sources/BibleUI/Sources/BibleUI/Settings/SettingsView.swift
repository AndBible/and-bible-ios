// SettingsView.swift — App settings

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
#if os(iOS)
import UIKit
#endif

/**
 Top-level application settings screen covering reader behavior, appearance, security, sync, and
 module-backed preference selection.

 The view mixes direct `TextDisplaySettings` bindings with persisted Android-parity preferences
 stored through `SettingsStore` and `UserDefaults`-backed `AppStorage`.

 Data dependencies:
 - `modelContext` is used to load and persist Android-parity settings through `SettingsStore`
 - `displaySettings`, `nightMode`, and `nightModeMode` are shared reader settings owned by the parent
 - `colorScheme` and `openURL` influence night-mode resolution and system-settings actions

 Side effects:
 - `onAppear` discovers installed modules, hydrates persisted preferences, sanitizes stale selections,
   and applies keep-screen-on / locale side effects
 - many toggles and pickers persist changes immediately through `SettingsStore`
 - dictionary, modal-action, and experimental-feature selections propagate through `onChange`
 - security and advanced actions may update `AppStorage`, open system settings, or schedule a debug crash
 */
public struct SettingsView: View {
    /// SwiftData context used to read and persist settings through `SettingsStore`.
    @Environment(\.modelContext) private var modelContext

    /// Current system color scheme used to resolve night-mode behavior.
    @Environment(\.colorScheme) private var colorScheme

    /// URL opener used for system-settings actions.
    @Environment(\.openURL) private var openURL

    /// Shared text display settings edited by nested settings screens.
    @Binding var displaySettings: TextDisplaySettings

    /// Shared effective night-mode state used by the reader.
    @Binding var nightMode: Bool

    /// Shared persisted night-mode switching mode (`system`, `manual`, or `automatic`).
    @Binding var nightModeMode: String

    /// Callback invoked when settings mutations should trigger reader refreshes.
    var onSettingsChanged: (() -> Void)?

    /// Installed dictionaries that advertise Greek Strong's definitions.
    @State private var strongsGreekDictionaries: [ModuleInfo] = []

    /// Installed dictionaries that advertise Hebrew Strong's definitions.
    @State private var strongsHebrewDictionaries: [ModuleInfo] = []

    /// Installed dictionaries that advertise Robinson morphology parsing.
    @State private var robinsonMorphologyDictionaries: [ModuleInfo] = []

    /// Installed general-purpose dictionaries available for word lookup.
    @State private var wordLookupDictionaries: [ModuleInfo] = []

    /// Explicitly enabled Greek Strong's dictionaries. Empty means "all enabled".
    @State private var selectedStrongsGreekDictionaryNames: Set<String> = []

    /// Explicitly enabled Hebrew Strong's dictionaries. Empty means "all enabled".
    @State private var selectedStrongsHebrewDictionaryNames: Set<String> = []

    /// Explicitly enabled Robinson morphology dictionaries. Empty means "all enabled".
    @State private var selectedRobinsonMorphologyDictionaryNames: Set<String> = []

    /// Explicitly disabled general word-lookup dictionaries.
    @State private var disabledWordLookupDictionaryNames: Set<String> = []

    /// Persisted discrete-mode security preference mirrored through AppStorage.
    @AppStorage(AppPreferenceKey.discreteMode.rawValue)
    private var discreteMode = AppPreferenceRegistry.boolDefault(for: .discreteMode) ?? false

    /// Persisted calculator-gate preference mirrored through AppStorage.
    @AppStorage(AppPreferenceKey.showCalculator.rawValue)
    private var showCalculator = AppPreferenceRegistry.boolDefault(for: .showCalculator) ?? false

    /// Persisted calculator PIN mirrored through AppStorage.
    @AppStorage(AppPreferenceKey.calculatorPin.rawValue)
    private var calculatorPin = AppPreferenceRegistry.stringDefault(for: .calculatorPin) ?? "1234"

    /// Whether link taps should open in the special links window.
    @State private var openLinksInSpecialWindow =
        AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref) ?? true

    /// Whether monochrome reader rendering is enabled.
    @State private var monochromeMode = AppPreferenceRegistry.boolDefault(for: .monochromeMode) ?? false

    /// Whether reader-side animations should be disabled.
    @State private var disableAnimations = AppPreferenceRegistry.boolDefault(for: .disableAnimations) ?? false

    /// Whether Study Pad click-to-edit should be disabled.
    @State private var disableClickToEdit = AppPreferenceRegistry.boolDefault(for: .disableClickToEdit) ?? false

    /// Whether the active reader window indicator should be shown.
    @State private var showActiveWindowIndicator =
        AppPreferenceRegistry.boolDefault(for: .showActiveWindowIndicator) ?? true

    /// Whether the JavaScript error box should be shown in debug builds.
    @State private var showErrorBox = AppPreferenceRegistry.boolDefault(for: .showErrorBox) ?? false

    /// Whether Bluetooth media buttons should control speaking features.
    @State private var enableBluetoothMediaButtons =
        AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref) ?? true

    /// Disabled one-tap actions for Bible bookmark modals.
    @State private var disabledBibleBookmarkModalButtons: Set<String> = []

    /// Disabled one-tap actions for general bookmark modals.
    @State private var disabledGenBookmarkModalButtons: Set<String> = []

    /// Global font size multiplier percentage applied to reader rendering.
    @State private var fontSizeMultiplier = AppPreferenceRegistry.intDefault(for: .fontSizeMultiplier) ?? 100

    /// Whether the bottom window button bar should hide in fullscreen mode.
    @State private var fullScreenHideButtons =
        AppPreferenceRegistry.boolDefault(for: .fullScreenHideButtonsPref) ?? true

    /// Whether in-window action buttons should be hidden in reader panes.
    @State private var hideWindowButtons =
        AppPreferenceRegistry.boolDefault(for: .hideWindowButtons) ?? false

    /// Whether the fullscreen Bible reference overlay should be hidden.
    @State private var hideBibleReferenceOverlay =
        AppPreferenceRegistry.boolDefault(for: .hideBibleReferenceOverlay) ?? false

    /// Whether navigation should include verse selection after choosing a chapter.
    @State private var navigateToVerse = AppPreferenceRegistry.boolDefault(for: .navigateToVersePref) ?? false

    /// Whether the app should keep the screen awake while in use.
    @State private var screenKeepOn = AppPreferenceRegistry.boolDefault(for: .screenKeepOnPref) ?? false

    /// Whether double-tapping a pane should toggle fullscreen.
    @State private var doubleTapToFullscreen =
        AppPreferenceRegistry.boolDefault(for: .doubleTapToFullscreen) ?? true

    /// Whether scrolling should automatically trigger fullscreen.
    @State private var autoFullscreen = AppPreferenceRegistry.boolDefault(for: .autoFullscreenPref) ?? false

    /// Whether Bible selection actions should use the one-step bookmarking flow.
    @State private var disableTwoStepBookmarking =
        AppPreferenceRegistry.boolDefault(for: .disableTwoStepBookmarking) ?? false

    /// Android-parity mode controlling Bible/commentary toolbar tap semantics.
    @State private var toolbarButtonActionsMode =
        AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions) ?? "default"

    /// Android-parity mode controlling horizontal swipe actions in the reader.
    @State private var bibleViewSwipeMode =
        AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode) ?? "CHAPTER"

    /// Persisted cross-platform preference for volume-key scrolling.
    @State private var volumeKeysScroll =
        AppPreferenceRegistry.boolDefault(for: .volumeKeysScroll) ?? true

    /// Enabled experimental feature identifiers.
    @State private var enabledExperimentalFeatures: Set<String> = []

    /// Persisted interface-language override aligned with Android locale values.
    @State private var selectedLanguage: String = AppPreferenceRegistry.stringDefault(for: .localePref) ?? ""

    /// Controls the restart-required alert shown after language changes.
    @State private var showRestartAlert = false

    /// Controls the discrete-mode help sheet presentation.
    @State private var showDiscreteHelp = false

    /// Guards locale persistence until initial preference hydration finishes.
    @State private var hasLoadedPreferences = false

    /// Tracks whether the debug crash action has already been scheduled.
    @State private var debugCrashScheduled = false

    /**
     Locale option mirroring one Android `locale_pref` entry.
     */
    private struct LocaleOption: Identifiable {
        /// Persisted locale value written to `locale_pref`.
        let value: String

        /// Localization key for the option label.
        let labelKey: String

        /// English fallback label used when the locale key is missing.
        let labelDefault: String

        /// Stable identity that preserves an explicit row for the default option.
        var id: String { value.isEmpty ? "__default" : value }
    }

    /**
     Experimental feature option mirroring one Android arrays.xml contract value.
     */
    fileprivate struct ExperimentalFeatureOption: Identifiable {
        /// Persisted feature identifier.
        let value: String

        /// Localization key for the feature title.
        let titleKey: String

        /// English fallback title used when the localization key is missing.
        let titleDefault: String

        /// Stable identity derived from the persisted feature identifier.
        var id: String { value }
    }

    /**
     One-tap bookmark modal action option mirroring Android arrays.xml identifiers.
     */
    fileprivate struct BookmarkModalActionOption: Identifiable {
        /// Persisted action identifier.
        let value: String

        /// Localization key for the action title.
        let titleKey: String

        /// English fallback title used when the localization key is missing.
        let titleDefault: String

        /// Stable identity derived from the persisted action identifier.
        var id: String { value }
    }

    /// Locale options mirror Android arrays.xml order/value contract.
    private static let localeOptions: [LocaleOption] = [
        .init(value: "", labelKey: "lang_default", labelDefault: "Default"),
        .init(value: "af", labelKey: "lang_afrikaans", labelDefault: "Afrikaans"),
        .init(value: "ar", labelKey: "lang_arabic", labelDefault: "Arabic"),
        .init(value: "bg", labelKey: "lang_bulgarian", labelDefault: "Bulgarian"),
        .init(value: "bn", labelKey: "lang_bengali", labelDefault: "Bengali"),
        .init(value: "my", labelKey: "lang_burmese", labelDefault: "Burmese"),
        .init(value: "cs", labelKey: "lang_czech", labelDefault: "Czech"),
        .init(value: "de", labelKey: "lang_german", labelDefault: "German"),
        .init(value: "en", labelKey: "lang_english", labelDefault: "English"),
        .init(value: "eo", labelKey: "lang_esperanto", labelDefault: "Esperanto"),
        .init(value: "es", labelKey: "lang_spanish", labelDefault: "Spanish"),
        .init(value: "et", labelKey: "lang_estonian", labelDefault: "Estonian"),
        .init(value: "fi", labelKey: "lang_finnish", labelDefault: "Finnish"),
        .init(value: "fr", labelKey: "lang_french", labelDefault: "French"),
        .init(value: "iw", labelKey: "lang_hebrew", labelDefault: "Hebrew"),
        .init(value: "hi", labelKey: "lang_hindi", labelDefault: "Hindi"),
        .init(value: "hr", labelKey: "lang_croatian", labelDefault: "Croatian"),
        .init(value: "hu", labelKey: "lang_hungarian", labelDefault: "Hungarian"),
        .init(value: "in", labelKey: "lang_indonesian", labelDefault: "Indonesian"),
        .init(value: "it", labelKey: "lang_italian", labelDefault: "Italian"),
        .init(value: "kk", labelKey: "lang_kazakh", labelDefault: "Kazakh"),
        .init(value: "ko", labelKey: "lang_korean", labelDefault: "Korean"),
        .init(value: "lt", labelKey: "lang_lithuanian", labelDefault: "Lithuanian"),
        .init(value: "nb", labelKey: "lang_norwegian_bokmal", labelDefault: "Norwegian Bokmal"),
        .init(value: "nl", labelKey: "lang_dutch", labelDefault: "Dutch"),
        .init(value: "pl", labelKey: "lang_polish", labelDefault: "Polish"),
        .init(value: "pt", labelKey: "lang_portuguese", labelDefault: "Portuguese"),
        .init(value: "pt-BR", labelKey: "lang_portuguese_brazil", labelDefault: "Portuguese (Brazil)"),
        .init(value: "ro", labelKey: "lang_romanian", labelDefault: "Romanian"),
        .init(value: "ru", labelKey: "lang_russian", labelDefault: "Russian"),
        .init(value: "sk", labelKey: "lang_slovak", labelDefault: "Slovak"),
        .init(value: "sl", labelKey: "lang_slovenian", labelDefault: "Slovenian"),
        .init(value: "sr", labelKey: "lang_serbian", labelDefault: "Serbian"),
        .init(value: "sr-Latn", labelKey: "lang_serbian_latin", labelDefault: "Serbian (Latin)"),
        .init(value: "ta", labelKey: "lang_tamil", labelDefault: "Tamil"),
        .init(value: "tr", labelKey: "lang_turkish", labelDefault: "Turkish"),
        .init(value: "te", labelKey: "lang_telugu", labelDefault: "Telugu"),
        .init(value: "uk", labelKey: "lang_ukrainian", labelDefault: "Ukrainian"),
        .init(value: "uz", labelKey: "lang_uzbek", labelDefault: "Uzbek"),
        .init(value: "yue", labelKey: "lang_cantonese", labelDefault: "Cantonese"),
        .init(value: "zh-Hant-TW", labelKey: "lang_chinese_traditional", labelDefault: "Chinese (Traditional)"),
        .init(value: "zh-Hans-CN", labelKey: "lang_chinese_simplified", labelDefault: "Chinese (Simplified)")
    ]

    /// Feature IDs mirror Android experimental_features_values.
    private static let experimentalFeatureOptions: [ExperimentalFeatureOption] = [
        .init(
            value: "bookmark_edit_actions",
            titleKey: "experimental_feature_bookmark_edit_actions",
            titleDefault: "Bookmark edit actions"
        ),
        .init(
            value: "add_paragraph_break",
            titleKey: "experimental_feature_add_paragraph_break",
            titleDefault: "Add paragraph break bookmark"
        )
    ]

    /// Android arrays.xml: prefs_bible_bookmark_modal_action_ids / _names.
    private static let bibleBookmarkModalActionOptions: [BookmarkModalActionOption] = [
        .init(value: "BOOKMARK", titleKey: "create_bookmark", titleDefault: "Create a new Bookmark"),
        .init(value: "BOOKMARK_NOTES", titleKey: "create_bookmark_with_a_note", titleDefault: "Create a new Bookmark with a note"),
        .init(value: "ADD_PARAGRAPH_BREAK", titleKey: "add_paragraph_break", titleDefault: "Paragraph break"),
        .init(value: "MY_NOTES", titleKey: "my_notes_abbreviation", titleDefault: "My Notes"),
        .init(value: "SHARE", titleKey: "share_verse_widget_title", titleDefault: "Share selection"),
        .init(value: "COMPARE", titleKey: "compare", titleDefault: "Compare"),
        .init(value: "SPEAK", titleKey: "speak", titleDefault: "Speak"),
        .init(value: "MEMORIZE", titleKey: "memorize_abbreviation", titleDefault: "Memorize")
    ]

    /// Android arrays.xml: prefs_gen_bookmark_modal_action_ids / _names.
    private static let genBookmarkModalActionOptions: [BookmarkModalActionOption] = [
        .init(value: "BOOKMARK", titleKey: "create_bookmark", titleDefault: "Create a new Bookmark"),
        .init(value: "BOOKMARK_NOTES", titleKey: "create_bookmark_with_a_note", titleDefault: "Create a new Bookmark with a note"),
        .init(value: "ADD_PARAGRAPH_BREAK", titleKey: "add_paragraph_break", titleDefault: "Paragraph break"),
        .init(value: "SPEAK", titleKey: "speak", titleDefault: "Speak")
    ]

    /**
     Creates the top-level settings screen bound to shared reader settings.

     - Parameters:
       - displaySettings: Shared text-display settings edited by nested settings views.
       - nightMode: Shared effective night-mode state used by the reader.
       - nightModeMode: Shared persisted night-mode mode string.
       - onSettingsChanged: Optional callback invoked when changes should refresh reader content.
     */
    public init(
        displaySettings: Binding<TextDisplaySettings>,
        nightMode: Binding<Bool>,
        nightModeMode: Binding<String>,
        onSettingsChanged: (() -> Void)? = nil
    ) {
        self._displaySettings = displaySettings
        self._nightMode = nightMode
        self._nightModeMode = nightModeMode
        self.onSettingsChanged = onSettingsChanged
    }

    /**
     Builds the full settings form, preference hydration, alerts, and settings-side effects.
     */
    public var body: some View {
        Form {
                settingsUITestShortcutSection

                if hasDictionaryPreferences {
                    Section(String(localized: "settings_dictionaries")) {
                        if !strongsGreekDictionaries.isEmpty {
                            NavigationLink {
                                DictionaryMultiSelectView(
                                    title: String(
                                        localized: "choose_strongs_greek_dictionary_title",
                                        defaultValue: "Strongs Greek dictionary"
                                    ),
                                    dictionaries: strongsGreekDictionaries,
                                    selectedNames: $selectedStrongsGreekDictionaryNames
                                )
                            } label: {
                                settingsSelectionRow(
                                    title: String(
                                        localized: "choose_strongs_greek_dictionary_title",
                                        defaultValue: "Strongs Greek dictionary"
                                    ),
                                    summary: String(
                                        localized: "choose_strongs_greek_dictionary_summary",
                                        defaultValue: "Choose Strongs dictionary for Greek word definitions"
                                    ),
                                    detail: selectionSummary(
                                        selectedNames: selectedStrongsGreekDictionaryNames,
                                        available: strongsGreekDictionaries
                                    )
                                )
                            }
                            .accessibilityIdentifier("settingsStrongsGreekDictionaryLink")
                        }

                        if !strongsHebrewDictionaries.isEmpty {
                            NavigationLink {
                                DictionaryMultiSelectView(
                                    title: String(
                                        localized: "choose_strongs_hebrew_dictionary_title",
                                        defaultValue: "Strongs Hebrew dictionary"
                                    ),
                                    dictionaries: strongsHebrewDictionaries,
                                    selectedNames: $selectedStrongsHebrewDictionaryNames
                                )
                            } label: {
                                settingsSelectionRow(
                                    title: String(
                                        localized: "choose_strongs_hebrew_dictionary_title",
                                        defaultValue: "Strongs Hebrew dictionary"
                                    ),
                                    summary: String(
                                        localized: "choose_strongs_hebrew_dictionary_summary",
                                        defaultValue: "Choose Strongs dictionary for Hebrew word definitions"
                                    ),
                                    detail: selectionSummary(
                                        selectedNames: selectedStrongsHebrewDictionaryNames,
                                        available: strongsHebrewDictionaries
                                    )
                                )
                            }
                            .accessibilityIdentifier("settingsStrongsHebrewDictionaryLink")
                        }

                        if !robinsonMorphologyDictionaries.isEmpty {
                            NavigationLink {
                                DictionaryMultiSelectView(
                                    title: String(
                                        localized: "choose_strongs_greek_morphology_title",
                                        defaultValue: "Robinson Greek morphology"
                                    ),
                                    dictionaries: robinsonMorphologyDictionaries,
                                    selectedNames: $selectedRobinsonMorphologyDictionaryNames
                                )
                            } label: {
                                settingsSelectionRow(
                                    title: String(
                                        localized: "choose_strongs_greek_morphology_title",
                                        defaultValue: "Robinson Greek morphology"
                                    ),
                                    summary: String(
                                        localized: "choose_strongs_greek_morphology_summary",
                                        defaultValue: "Choose dictionary for Robinson Greek morphology definitions"
                                    ),
                                    detail: selectionSummary(
                                        selectedNames: selectedRobinsonMorphologyDictionaryNames,
                                        available: robinsonMorphologyDictionaries
                                    )
                                )
                            }
                            .accessibilityIdentifier("settingsRobinsonMorphologyLink")
                        }

                        if !wordLookupDictionaries.isEmpty {
                            NavigationLink {
                                DictionaryInverseMultiSelectView(
                                    title: String(
                                        localized: "choose_word_lookup_dictionary_title",
                                        defaultValue: "Word lookup dictionaries"
                                    ),
                                    dictionaries: wordLookupDictionaries,
                                    disabledNames: $disabledWordLookupDictionaryNames
                                )
                            } label: {
                                settingsSelectionRow(
                                    title: String(
                                        localized: "choose_word_lookup_dictionary_title",
                                        defaultValue: "Word lookup dictionaries"
                                    ),
                                    summary: String(
                                        localized: "choose_word_lookup_dictionary_summary",
                                        defaultValue: "Choose dictionaries for looking up words"
                                    ),
                                    detail: inverseSelectionSummary(
                                        disabledNames: disabledWordLookupDictionaryNames,
                                        available: wordLookupDictionaries
                                    )
                                )
                            }
                            .accessibilityIdentifier("settingsWordLookupDictionariesLink")
                        }
                    }
                }

                Section(String(localized: "prefs_behavior_customization_cat", defaultValue: "Application behavior")) {
                    Toggle(
                        String(
                            localized: "prefs_navigate_to_verse_title",
                            defaultValue: "Navigate to verse"
                        ),
                        isOn: Binding(
                            get: { navigateToVerse },
                            set: { newValue in
                                navigateToVerse = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.navigateToVersePref, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_navigate_to_verse_summary",
                        defaultValue: "Choose verse (and chapter) when selecting a passage"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        String(localized: "prefs_screen_keep_on_title", defaultValue: "Keep screen on"),
                        isOn: Binding(
                            get: { screenKeepOn },
                            set: { newValue in
                                screenKeepOn = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.screenKeepOnPref, value: newValue)
                                applyScreenKeepOn(newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_screen_keep_on_summary",
                        defaultValue: "Prevent screen sleeping while using this app"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        String(
                            localized: "prefs_double_tap_to_fullscreen_title",
                            defaultValue: "Double-tap to Fullscreen"
                        ),
                        isOn: Binding(
                            get: { doubleTapToFullscreen },
                            set: { newValue in
                                doubleTapToFullscreen = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.doubleTapToFullscreen, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_double_tap_to_fullscreen_summary",
                        defaultValue: "Enter fullscreen mode by double-tapping window"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        String(localized: "auto_fullscreen", defaultValue: "Fullscreen by scrolling"),
                        isOn: Binding(
                            get: { autoFullscreen },
                            set: { newValue in
                                autoFullscreen = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.autoFullscreenPref, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "auto_fullscreen_summary",
                        defaultValue: "Switch automatically to fullscreen when scrolling text. Tip: you can always also switch to full screen by doubletapping screen."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        String(
                            localized: "prefs_toolbar_button_action_title",
                            defaultValue: "Bible/commentary toolbar button action"
                        ),
                        selection: Binding(
                            get: { Self.normalizedToolbarButtonActionsMode(toolbarButtonActionsMode) },
                            set: { newValue in
                                toolbarButtonActionsMode = Self.normalizedToolbarButtonActionsMode(newValue)
                                let store = SettingsStore(modelContext: modelContext)
                                store.setString(.toolbarButtonActions, value: toolbarButtonActionsMode)
                            }
                        )
                    ) {
                        Text(String(localized: "prefs_toolbar_button_action_default", defaultValue: "Default"))
                            .tag("default")
                        Text(String(localized: "prefs_toolbar_button_action_swap_menu", defaultValue: "Swap menu"))
                            .tag("swap-menu")
                        Text(String(localized: "prefs_toolbar_button_action_swap_activity", defaultValue: "Swap activity"))
                            .tag("swap-activity")
                    }
                    Text(String(
                        localized: "prefs_toolbar_button_action_summary",
                        defaultValue: "Choose if one-tap of Bible/commentary toolbar buttons shows menu or activity directly."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        String(
                            localized: "prefs_disable_two_step_bookmarking_title",
                            defaultValue: "One-step bookmarking"
                        ),
                        isOn: Binding(
                            get: { disableTwoStepBookmarking },
                            set: { newValue in
                                disableTwoStepBookmarking = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.disableTwoStepBookmarking, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_disable_two_step_bookmarking_summary",
                        defaultValue: "Show \"Selection\" and \"Verses\" items directly in Bible view Selection menu"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        String(
                            localized: "prefs_bible_view_swipe_mode_title",
                            defaultValue: "Action for swipe left / right gesture"
                        ),
                        selection: Binding(
                            get: { Self.normalizedBibleViewSwipeMode(bibleViewSwipeMode) },
                            set: { newValue in
                                bibleViewSwipeMode = Self.normalizedBibleViewSwipeMode(newValue)
                                let store = SettingsStore(modelContext: modelContext)
                                store.setString(.bibleViewSwipeMode, value: bibleViewSwipeMode)
                            }
                        )
                    ) {
                        Text(String(localized: "prefs_swipe_mode_chapter", defaultValue: "Chapter"))
                            .tag("CHAPTER")
                        Text(String(localized: "prefs_swipe_mode_page", defaultValue: "Page"))
                            .tag("PAGE")
                        Text(String(localized: "prefs_swipe_mode_none", defaultValue: "None"))
                            .tag("NONE")
                    }
                    Text(String(
                        localized: "prefs_bible_view_swipe_mode_summary",
                        defaultValue: "Swipe left / right gesture can be used to go to next page / chapter."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        String(
                            localized: "prefs_volume_keys_scroll_title",
                            defaultValue: "Volume buttons scroll"
                        ),
                        isOn: Binding(
                            get: { volumeKeysScroll },
                            set: { newValue in
                                volumeKeysScroll = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.volumeKeysScroll, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_volume_keys_scroll_summary",
                        defaultValue: "Use volume up/down to scroll Bible text"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(
                        localized: "prefs_volume_keys_scroll_ios_note",
                        defaultValue: "iOS does not expose volume-button presses to apps. This setting is kept for Android parity and cross-device sync."
                    ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Toggle(String(localized: "verse_selection"), isOn: Binding(
                        get: { displaySettings.enableVerseSelection ?? true },
                        set: {
                            displaySettings.enableVerseSelection = $0
                            onSettingsChanged?()
                        }
                    ))
                    Toggle(
                        String(
                            localized: "prefs_open_links_in_special_window_title",
                            defaultValue: "Links window"
                        ),
                        isOn: Binding(
                            get: { openLinksInSpecialWindow },
                            set: { newValue in
                                openLinksInSpecialWindow = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.openLinksInSpecialWindowPref, value: newValue)
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_open_links_in_special_window_summary",
                        defaultValue: "Open links in special window, for quicker display of cross-references and Strongs"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                lookAndFeelSection

                Section(String(localized: "settings_security")) {
                    Button {
                        showDiscreteHelp = true
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text(String(localized: "discrete_help_title"))
                                    .foregroundStyle(.primary)
                                Text(String(localized: "discrete_help_summary"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Toggle(String(localized: "discrete_mode"), isOn: $discreteMode)
                    Text(String(localized: "discrete_mode_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(String(localized: "show_calculator"), isOn: $showCalculator)
                    Text(String(localized: "show_calculator_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(String(localized: "calculator_pin"))
                        Spacer()
                        TextField(String(localized: "calculator_pin_placeholder"), text: $calculatorPin)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .onChange(of: calculatorPin) { _, newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if filtered != newValue { calculatorPin = filtered }
                            }
                    }
                    Text(String(localized: "calculator_pin_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "prefs_advanced_settings_cat", defaultValue: "Advanced settings")) {
                    Toggle(
                        String(
                            localized: "prefs_enable_bluetooth_title",
                            defaultValue: "Enable Bluetooth media buttons"
                        ),
                        isOn: Binding(
                            get: { enableBluetoothMediaButtons },
                            set: { newValue in
                                enableBluetoothMediaButtons = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.enableBluetoothPref, value: newValue)
                                onSettingsChanged?()
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_enable_bluetooth_summary",
                        defaultValue: "Handle Bluetooth media buttons to start/stop speaking."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        ExperimentalFeaturesMultiSelectView(
                            title: String(
                                localized: "prefs_experimental_features_title",
                                defaultValue: "Experimental features"
                            ),
                            options: Self.experimentalFeatureOptions,
                            selectedValues: $enabledExperimentalFeatures
                        )
                    } label: {
                        settingsSelectionRow(
                            title: String(
                                localized: "prefs_experimental_features_title",
                                defaultValue: "Experimental features"
                            ),
                            summary: String(
                                localized: "prefs_experimental_features_summary",
                                defaultValue: "Select which experimental features to enable. These features are still in development and may change or be removed"
                            ),
                            detail: experimentalFeaturesSummary(selectedValues: enabledExperimentalFeatures)
                        )
                    }
                    #if DEBUG
                    Toggle(
                        String(
                            localized: "prefs_show_error_box_title",
                            defaultValue: "Show Javascript error box"
                        ),
                        isOn: Binding(
                            get: { showErrorBox },
                            set: { newValue in
                                showErrorBox = newValue
                                let store = SettingsStore(modelContext: modelContext)
                                store.setBool(.showErrorBox, value: newValue)
                                onSettingsChanged?()
                            }
                        )
                    )
                    Text(String(
                        localized: "prefs_show_error_box_summary",
                        defaultValue: "Useful for developers when debugging BibleView javascript side errors. This will make the app slower."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif

                    #if os(iOS)
                    Button {
                        openBibleLinkSystemSettings()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(
                                    localized: "open_bible_links_title",
                                    defaultValue: "Open Bible links in AndBible"
                                ))
                                    .foregroundStyle(.primary)
                                Text(String(
                                    localized: "open_bible_links_summary",
                                    defaultValue: "When clicking links that refer to AndBible supported Bible URL, open them in AndBible"
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                    #endif

                    #if DEBUG
                    Button(role: .destructive) {
                        triggerDebugCrash()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(
                                    localized: "crash_app",
                                    defaultValue: "Crash app!"
                                ))
                                .foregroundStyle(.red)
                                Text(debugCrashScheduled
                                    ? String(
                                        localized: "crash_app_scheduled_summary",
                                        defaultValue: "Crash scheduled in 10 seconds."
                                    )
                                    : String(
                                        localized: "crash_app_summary",
                                        defaultValue: "Crash app after 10 seconds. Debugging feature, visible only in debug builds."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    .disabled(debugCrashScheduled)
                    #endif
                }

                Section(String(localized: "settings_data")) {
                    settingsNavigationLink(
                        title: String(localized: "downloads"),
                        accessibilityIdentifier: "settingsDownloadsLink"
                    ) {
                        ModuleBrowserView()
                    }
                    settingsNavigationLink(
                        title: String(localized: "repositories"),
                        accessibilityIdentifier: "settingsRepositoriesLink"
                    ) {
                        RepositoryManagerView()
                    }
                    settingsNavigationLink(
                        title: String(localized: "import_export"),
                        accessibilityIdentifier: "settingsImportExportLink"
                    ) {
                        ImportExportView()
                    }
                    settingsNavigationLink(
                        title: String(localized: "icloud_sync"),
                        accessibilityIdentifier: "settingsSyncLink"
                    ) {
                        SyncSettingsView()
                    }
                    settingsNavigationLink(
                        title: String(localized: "labels"),
                        accessibilityIdentifier: "settingsLabelsLink"
                    ) {
                        LabelManagerView()
                    }
                }

                Section(String(localized: "settings_about")) {
                    HStack {
                        Text(String(localized: "version"))
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("settingsForm")
            .accessibilityValue(settingsAccessibilityValue)
            .navigationTitle(String(localized: "settings"))
            .alert(
                String(localized: "prefs_interface_locale_title", defaultValue: "Application language"),
                isPresented: $showRestartAlert
            ) {
                Button(String(localized: "ok")) {}
            } message: {
                Text(String(localized: "language_restart_required"))
            }
            .sheet(isPresented: $showDiscreteHelp) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(String(localized: "discrete_help_par1"))
                            Text(String(localized: "discrete_help_par2"))
                            Text(String(localized: "discrete_help_par3"))
                            Text(String(localized: "discrete_help_ios_note"))
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .navigationTitle(String(localized: "settings_security"))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "done")) { showDiscreteHelp = false }
                        }
                    }
                }
            }
            .onAppear {
                // Load installed dictionary modules
                if let mgr = SwordManager() {
                    let all = mgr.installedModules()
                    strongsGreekDictionaries = all
                        .filter {
                            ($0.category == .dictionary || $0.category == .glossary) &&
                                $0.features.contains(.greekDef)
                        }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    strongsHebrewDictionaries = all
                        .filter {
                            ($0.category == .dictionary || $0.category == .glossary) &&
                                $0.features.contains(.hebrewDef)
                        }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    robinsonMorphologyDictionaries = all
                        .filter {
                            ($0.category == .dictionary || $0.category == .glossary) &&
                                $0.features.contains(.greekParse)
                        }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    wordLookupDictionaries = all
                        .filter {
                            $0.category == .dictionary &&
                                !$0.features.contains(.greekDef) &&
                                !$0.features.contains(.hebrewDef) &&
                                !$0.features.contains(.greekParse)
                        }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                hasLoadedPreferences = false
                // Load persisted preferences
                let store = SettingsStore(modelContext: modelContext)
                selectedStrongsGreekDictionaryNames = Set(store.getStringSet(.strongsGreekDictionary))
                selectedStrongsHebrewDictionaryNames = Set(store.getStringSet(.strongsHebrewDictionary))
                selectedRobinsonMorphologyDictionaryNames = Set(store.getStringSet(.robinsonGreekMorphology))
                disabledWordLookupDictionaryNames = Set(store.getStringSet(.disabledWordLookupDictionaries))
                disabledBibleBookmarkModalButtons = Set(store.getStringSet(.disableBibleBookmarkModalButtons))
                disabledGenBookmarkModalButtons = Set(store.getStringSet(.disableGenBookmarkModalButtons))
                sanitizeDictionaryPreferences(store: store)
                sanitizeBookmarkModalActionPreferences(store: store)
                openLinksInSpecialWindow = store.getBool(.openLinksInSpecialWindowPref)
                monochromeMode = store.getBool(.monochromeMode)
                disableAnimations = store.getBool(.disableAnimations)
                disableClickToEdit = store.getBool(.disableClickToEdit)
                showActiveWindowIndicator = store.getBool(.showActiveWindowIndicator)
                showErrorBox = store.getBool(.showErrorBox)
                enableBluetoothMediaButtons = store.getBool(.enableBluetoothPref)
                fontSizeMultiplier = store.getInt(.fontSizeMultiplier)
                fullScreenHideButtons = store.getBool(.fullScreenHideButtonsPref)
                hideWindowButtons = store.getBool(.hideWindowButtons)
                hideBibleReferenceOverlay = store.getBool(.hideBibleReferenceOverlay)
                navigateToVerse = store.getBool(.navigateToVersePref)
                screenKeepOn = store.getBool(.screenKeepOnPref)
                doubleTapToFullscreen = store.getBool(.doubleTapToFullscreen)
                autoFullscreen = store.getBool(.autoFullscreenPref)
                disableTwoStepBookmarking = store.getBool(.disableTwoStepBookmarking)
                toolbarButtonActionsMode = Self.normalizedToolbarButtonActionsMode(
                    store.getString(.toolbarButtonActions)
                )
                bibleViewSwipeMode = Self.normalizedBibleViewSwipeMode(store.getString(.bibleViewSwipeMode))
                volumeKeysScroll = store.getBool(.volumeKeysScroll)
                enabledExperimentalFeatures = Set(store.getStringSet(.experimentalFeatures))
                sanitizeExperimentalFeatures(store: store)
                nightModeMode = store.getString(.nightModePref3)
                let manualNightMode = store.getBool("night_mode")
                nightMode = NightModeSettingsResolver.isNightMode(
                    rawValue: nightModeMode,
                    manualNightMode: manualNightMode,
                    systemIsDark: colorScheme == .dark
                )
                applyScreenKeepOn(screenKeepOn)
                // Load locale_pref first. Fallback to any existing AppleLanguages override from older builds.
                let persistedLocale = store.getString(.localePref)
                if Self.localeOptions.contains(where: { $0.value == persistedLocale }) {
                    selectedLanguage = persistedLocale
                } else {
                    selectedLanguage = ""
                    if !persistedLocale.isEmpty {
                        store.setString(.localePref, value: "")
                    }
                }
                if selectedLanguage.isEmpty,
                   let overrideLangs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
                   let first = overrideLangs.first,
                   let mapped = Self.localePrefValue(forAppleLanguage: first) {
                    selectedLanguage = mapped
                    store.setString(.localePref, value: mapped)
                }
                hasLoadedPreferences = true
            }
            .onChange(of: selectedStrongsGreekDictionaryNames) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.strongsGreekDictionary, values: Array(newValue))
            }
            .onChange(of: selectedStrongsHebrewDictionaryNames) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.strongsHebrewDictionary, values: Array(newValue))
            }
            .onChange(of: selectedRobinsonMorphologyDictionaryNames) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.robinsonGreekMorphology, values: Array(newValue))
            }
            .onChange(of: disabledWordLookupDictionaryNames) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.disabledWordLookupDictionaries, values: Array(newValue))
            }
            .onChange(of: disabledBibleBookmarkModalButtons) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.disableBibleBookmarkModalButtons, values: Array(newValue))
                onSettingsChanged?()
            }
            .onChange(of: disabledGenBookmarkModalButtons) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.disableGenBookmarkModalButtons, values: Array(newValue))
                onSettingsChanged?()
            }
            .onChange(of: enabledExperimentalFeatures) { _, newValue in
                let store = SettingsStore(modelContext: modelContext)
                store.setStringSet(.experimentalFeatures, values: Array(newValue))
                onSettingsChanged?()
            }
    }

    @ViewBuilder
    /**
     Builds the "Look & feel" section, including nested display editors and appearance toggles.
     */
    private var lookAndFeelSection: some View {
        Section(String(localized: "prefs_display_customization_cat", defaultValue: "Look & feel")) {
            settingsNavigationLink(
                title: String(localized: "settings_text_display"),
                accessibilityIdentifier: "settingsTextDisplayLink"
            ) {
                TextDisplaySettingsView(settings: $displaySettings, onChange: onSettingsChanged)
            }
            settingsNavigationLink(
                title: String(localized: "settings_colors"),
                accessibilityIdentifier: "settingsColorsLink"
            ) {
                ColorSettingsView(settings: $displaySettings, onChange: onSettingsChanged)
            }
            Picker(
                String(localized: "prefs_night_mode_title", defaultValue: "Night mode switching"),
                selection: Binding(
                    get: { Self.nightModePickerSelection(from: nightModeMode) },
                    set: { newValue in
                        nightModeMode = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setString(.nightModePref3, value: newValue)
                        let manualNightMode = store.getBool("night_mode")
                        nightMode = NightModeSettingsResolver.isNightMode(
                            rawValue: newValue,
                            manualNightMode: manualNightMode,
                            systemIsDark: colorScheme == .dark
                        )
                        onSettingsChanged?()
                    }
                )
            ) {
                ForEach(NightModeSettingsResolver.availableModes, id: \.rawValue) { mode in
                    Text(Self.nightModeModeTitle(mode)).tag(mode.rawValue)
                }
            }
            Text(String(
                localized: "prefs_night_mode_summary",
                defaultValue: "Whether to switch to night mode manually or via system setting. Manual switching can be done from the 3-dot options menu on the main screen."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(localized: "prefs_e_ink_mode_title", defaultValue: "Black & white mode"),
                isOn: Binding(
                    get: { monochromeMode },
                    set: { newValue in
                        monochromeMode = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.monochromeMode, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "prefs_eink_mode_summary",
                defaultValue: "Use application in monochrome mode (no colors), making it more suitable for E-ink devices."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(localized: "prefs_disable_animations_title", defaultValue: "Disable animations"),
                isOn: Binding(
                    get: { disableAnimations },
                    set: { newValue in
                        disableAnimations = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.disableAnimations, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "prefs_disable_animations_summary",
                defaultValue: "Disable various animations such as smooth scrolling."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(
                    localized: "prefs_disable_click_to_edit_title",
                    defaultValue: "Disable Study Pad click-to-edit"
                ),
                isOn: Binding(
                    get: { disableClickToEdit },
                    set: { newValue in
                        disableClickToEdit = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.disableClickToEdit, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "prefs_disable_click_to_edit_summary",
                defaultValue: "Requires using the edit button to edit notes in the Study Pad."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                value: Binding(
                    get: { fontSizeMultiplier },
                    set: { newValue in
                        fontSizeMultiplier = min(max(newValue, 10), 500)
                        let store = SettingsStore(modelContext: modelContext)
                        store.setInt(.fontSizeMultiplier, value: fontSizeMultiplier)
                        onSettingsChanged?()
                    }
                ),
                in: 10...500,
                step: 10
            ) {
                HStack {
                    Text(String(
                        localized: "pref_font_size_multiplier_title",
                        defaultValue: "Font size multiplier"
                    ))
                    Spacer()
                    Text("\(fontSizeMultiplier)%")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(
                String(
                    localized: "full_screen_hide_buttons_pref_title",
                    defaultValue: "Hide window button bar in fullscreen"
                ),
                isOn: Binding(
                    get: { fullScreenHideButtons },
                    set: { newValue in
                        fullScreenHideButtons = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.fullScreenHideButtonsPref, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "full_screen_hide_buttons_pref_summary",
                defaultValue: "When switching to fullscreen mode, hide automatically window button bar that is on the bottom of the screen"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(
                    localized: "hide_window_buttons_title",
                    defaultValue: "Hide window buttons"
                ),
                isOn: Binding(
                    get: { hideWindowButtons },
                    set: { newValue in
                        hideWindowButtons = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.hideWindowButtons, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "hide_window_buttons_summary",
                defaultValue: "Window buttons that are displayed on right side of the Bible views are hidden. Window navigation bar on the bottom is still displayed and you may open window popup menu by long-clicking them."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(
                    localized: "hide_bible_reference_overlay_title",
                    defaultValue: "Hide Bible reference overlay"
                ),
                isOn: Binding(
                    get: { hideBibleReferenceOverlay },
                    set: { newValue in
                        hideBibleReferenceOverlay = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.hideBibleReferenceOverlay, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "hide_bible_reference_overlay_summary",
                defaultValue: "Do not show the semi-transparent Bible reference overlay when app is in fullscreen mode"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(
                String(
                    localized: "active_window_indicator_title",
                    defaultValue: "Show active window indicator"
                ),
                isOn: Binding(
                    get: { showActiveWindowIndicator },
                    set: { newValue in
                        showActiveWindowIndicator = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.showActiveWindowIndicator, value: newValue)
                        onSettingsChanged?()
                    }
                )
            )
            Text(String(
                localized: "active_window_indicator_summary",
                defaultValue: "Highlight window corners to help recognising which window is active"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationLink {
                BookmarkModalActionsInverseMultiSelectView(
                    title: String(
                        localized: "prefs_in_window_bible_bookmark_modal_buttons_title",
                        defaultValue: "One-tap actions (Bibles)"
                    ),
                    options: Self.bibleBookmarkModalActionOptions,
                    disabledValues: $disabledBibleBookmarkModalButtons
                )
            } label: {
                settingsSelectionRow(
                    title: String(
                        localized: "prefs_in_window_bible_bookmark_modal_buttons_title",
                        defaultValue: "One-tap actions (Bibles)"
                    ),
                    summary: String(
                        localized: "prefs_in_window_bookmark_modal_buttons_description",
                        defaultValue: "When a text is tapped, one-tap action window is shown. Which action buttons should be shown?"
                    ),
                    detail: inverseSelectionSummary(
                        disabledValues: disabledBibleBookmarkModalButtons,
                        options: Self.bibleBookmarkModalActionOptions
                    )
                )
            }
            NavigationLink {
                BookmarkModalActionsInverseMultiSelectView(
                    title: String(
                        localized: "prefs_in_window_gen_bookmark_modal_buttons_title",
                        defaultValue: "One-tap actions (Other)"
                    ),
                    options: Self.genBookmarkModalActionOptions,
                    disabledValues: $disabledGenBookmarkModalButtons
                )
            } label: {
                settingsSelectionRow(
                    title: String(
                        localized: "prefs_in_window_gen_bookmark_modal_buttons_title",
                        defaultValue: "One-tap actions (Other)"
                    ),
                    summary: String(
                        localized: "prefs_in_window_bookmark_modal_buttons_description",
                        defaultValue: "When a text is tapped, one-tap action window is shown. Which action buttons should be shown?"
                    ),
                    detail: inverseSelectionSummary(
                        disabledValues: disabledGenBookmarkModalButtons,
                        options: Self.genBookmarkModalActionOptions
                    )
                )
            }
            Picker(
                String(localized: "prefs_interface_locale_title", defaultValue: "Application language"),
                selection: $selectedLanguage
            ) {
                ForEach(Self.localeOptions) { lang in
                    Text(Self.localizedLocaleOptionLabel(lang)).tag(lang.value)
                }
            }
            .onChange(of: selectedLanguage) { _, newValue in
                guard hasLoadedPreferences else { return }
                let normalized = Self.localeOptions.contains(where: { $0.value == newValue }) ? newValue : ""
                if normalized != selectedLanguage {
                    selectedLanguage = normalized
                    return
                }

                let store = SettingsStore(modelContext: modelContext)
                guard shouldPersistLanguageSelection(normalized, using: store) else {
                    return
                }
                store.setString(.localePref, value: normalized)

                if let mapped = Self.appleLanguageCode(forLocalePrefValue: normalized) {
                    UserDefaults.standard.set([mapped], forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                }
                UserDefaults.standard.synchronize()
                showRestartAlert = true
            }
            Text(String(
                localized: "prefs_interface_locale_summary",
                defaultValue: "Select custom user interface language"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "language_restart_required"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether any module-backed dictionary preference sections should be shown.
    private var hasDictionaryPreferences: Bool {
        !strongsGreekDictionaries.isEmpty ||
            !strongsHebrewDictionaries.isEmpty ||
            !robinsonMorphologyDictionaries.isEmpty ||
            !wordLookupDictionaries.isEmpty
    }

    @ViewBuilder
    /**
     Builds the common title/summary/detail row used by selection-style settings links.
     */
    private func settingsSelectionRow(title: String, summary: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    /**
     Builds one Settings navigation row using the same `NavigationLink` semantics as production.
     *
     * This preserves the native list-row interaction model instead of routing navigation through
     * test-only state toggles.
     */
    private func settingsNavigationLink<Destination: View>(
        title: String,
        accessibilityIdentifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingsNavigationRow(title: title)
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    /**
     Builds a single-line navigation row used by nested settings links.
     *
     * - Parameter title: User-visible title shown in the row.
     * - Returns: Row content suitable for use as a `NavigationLink` label inside the settings form.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func settingsNavigationRow(title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var settingsUITestShortcutSection: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Section(String(localized: "settings", defaultValue: "Settings")) {
                settingsNavigationLink(
                    title: String(localized: "downloads"),
                    accessibilityIdentifier: "settingsDownloadsLink"
                ) {
                    ModuleBrowserView()
                }
                settingsNavigationLink(
                    title: String(localized: "repositories"),
                    accessibilityIdentifier: "settingsRepositoriesLink"
                ) {
                    RepositoryManagerView()
                }
                settingsNavigationLink(
                    title: String(localized: "import_export"),
                    accessibilityIdentifier: "settingsImportExportLink"
                ) {
                    ImportExportView()
                }
                settingsNavigationLink(
                    title: String(localized: "icloud_sync"),
                    accessibilityIdentifier: "settingsSyncLink"
                ) {
                    SyncSettingsView()
                }
                settingsNavigationLink(
                    title: String(localized: "labels"),
                    accessibilityIdentifier: "settingsLabelsLink"
                ) {
                    LabelManagerView()
                }
                settingsNavigationLink(
                    title: String(localized: "settings_text_display"),
                    accessibilityIdentifier: "settingsTextDisplayLink"
                ) {
                    TextDisplaySettingsView(settings: $displaySettings, onChange: onSettingsChanged)
                }
                settingsNavigationLink(
                    title: String(localized: "settings_colors"),
                    accessibilityIdentifier: "settingsColorsLink"
                ) {
                    ColorSettingsView(settings: $displaySettings, onChange: onSettingsChanged)
                }
            }
        }
    }

    private var settingsAccessibilityValue: String {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return ""
        }
        let primaryLinks = [
            "settingsDownloadsLink",
            "settingsRepositoriesLink",
            "settingsImportExportLink",
            "settingsSyncLink",
            "settingsLabelsLink",
            "settingsTextDisplayLink",
            "settingsColorsLink",
        ].joined(separator: ",")
        return "primaryLinks=\(primaryLinks)"
    }

    /**
     Returns whether applying a language selection would change persisted locale state.

     This prevents the restart-required alert from appearing when SwiftUI replays the locale picker
     selection after initial hydration even though both the Android-parity `locale_pref` value and
     the effective Apple language override already match the selected value.

     - Parameters:
       - normalized: Candidate locale value normalized against the supported `locale_pref` list.
       - store: Settings store used to read the persisted Android-parity locale value.
     - Returns: `true` when persisting the selection would change either stored locale source.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func shouldPersistLanguageSelection(_ normalized: String, using store: SettingsStore) -> Bool {
        let storedLocale = Self.normalizedLocalePrefValue(store.getString(.localePref))
        let appleLocale = (
            (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?
                .first
                .flatMap(Self.localePrefValue(forAppleLanguage:))
        ) ?? ""
        return normalized != storedLocale || normalized != appleLocale
    }

    /**
     Summarizes an explicit-selection dictionary preference using Android's empty-means-all semantics.

     - Parameters:
       - selectedNames: Explicitly selected module names, where an empty set means "all".
       - available: Installed modules currently available for the preference.
     - Returns: User-visible summary text for the current selection.
     */
    private func selectionSummary(selectedNames: Set<String>, available: [ModuleInfo]) -> String {
        guard !available.isEmpty else {
            return String(localized: "prefs_swipe_mode_none", defaultValue: "None")
        }
        let availableNames = Set(available.map(\.name))
        let effectiveSelected = selectedNames.isEmpty ? availableNames : selectedNames.intersection(availableNames)
        if effectiveSelected.count >= availableNames.count {
            return String(localized: "all", defaultValue: "All")
        }
        return String(format: String(localized: "%lld selected"), effectiveSelected.count)
    }

    /**
     Summarizes an inverse-selection dictionary preference where the stored set represents disabled modules.

     - Parameters:
       - disabledNames: Explicitly disabled module names.
       - available: Installed modules currently available for the preference.
     - Returns: User-visible summary text for the enabled dictionary count.
     */
    private func inverseSelectionSummary(disabledNames: Set<String>, available: [ModuleInfo]) -> String {
        guard !available.isEmpty else {
            return String(localized: "prefs_swipe_mode_none", defaultValue: "None")
        }
        let availableNames = Set(available.map(\.name))
        let enabledCount = availableNames.subtracting(disabledNames).count
        if enabledCount >= availableNames.count {
            return String(localized: "all", defaultValue: "All")
        }
        return String(format: String(localized: "%lld selected"), enabledCount)
    }

    /**
     Summarizes inverse-selection bookmark modal action preferences.

     - Parameters:
       - disabledValues: Persisted disabled action identifiers.
       - options: Full Android-parity option set for the modal type.
     - Returns: User-visible summary text for the enabled action count.
     */
    private func inverseSelectionSummary(
        disabledValues: Set<String>,
        options: [BookmarkModalActionOption]
    ) -> String {
        guard !options.isEmpty else {
            return String(localized: "prefs_swipe_mode_none", defaultValue: "None")
        }
        let availableValues = Set(options.map(\.value))
        let enabledCount = availableValues.subtracting(disabledValues).count
        if enabledCount >= availableValues.count {
            return String(localized: "all", defaultValue: "All")
        }
        return String(format: String(localized: "%lld selected"), enabledCount)
    }

    /**
     Builds the comma-separated summary for enabled experimental features.
     */
    private func experimentalFeaturesSummary(selectedValues: Set<String>) -> String {
        guard !selectedValues.isEmpty else {
            return String(localized: "prefs_swipe_mode_none", defaultValue: "Disabled")
        }
        let labels = Self.experimentalFeatureOptions
            .filter { selectedValues.contains($0.value) }
            .map { Self.localizedExperimentalFeatureTitle($0) }
        if labels.isEmpty {
            return String(localized: "prefs_swipe_mode_none", defaultValue: "Disabled")
        }
        return labels.joined(separator: ", ")
    }

    /**
     Applies the keep-screen-on preference to the platform idle timer.
     */
    private func applyScreenKeepOn(_ enabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = enabled
        #endif
    }

    /**
     Opens the closest iOS system settings destination available for Bible-link handling.
     */
    private func openBibleLinkSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }

    /**
     Schedules a deliberate debug crash after a 10-second delay.
     */
    private func triggerDebugCrash() {
        #if DEBUG
        guard !debugCrashScheduled else { return }
        debugCrashScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            fatalError("Crash app!")
        }
        #endif
    }

    /**
     Removes persisted dictionary selections that no longer exist in the current module lists.

     The stored selection keeps Android semantics where an empty selected set means "all enabled".
     */
    private func sanitizeDictionaryPreferences(store: SettingsStore) {
        let validGreek = Set(strongsGreekDictionaries.map(\.name))
        if !selectedStrongsGreekDictionaryNames.isEmpty {
            let sanitized = selectedStrongsGreekDictionaryNames.intersection(validGreek)
            if sanitized != selectedStrongsGreekDictionaryNames {
                selectedStrongsGreekDictionaryNames = sanitized
                store.setStringSet(.strongsGreekDictionary, values: Array(sanitized))
            }
        }

        let validHebrew = Set(strongsHebrewDictionaries.map(\.name))
        if !selectedStrongsHebrewDictionaryNames.isEmpty {
            let sanitized = selectedStrongsHebrewDictionaryNames.intersection(validHebrew)
            if sanitized != selectedStrongsHebrewDictionaryNames {
                selectedStrongsHebrewDictionaryNames = sanitized
                store.setStringSet(.strongsHebrewDictionary, values: Array(sanitized))
            }
        }

        let validMorph = Set(robinsonMorphologyDictionaries.map(\.name))
        if !selectedRobinsonMorphologyDictionaryNames.isEmpty {
            let sanitized = selectedRobinsonMorphologyDictionaryNames.intersection(validMorph)
            if sanitized != selectedRobinsonMorphologyDictionaryNames {
                selectedRobinsonMorphologyDictionaryNames = sanitized
                store.setStringSet(.robinsonGreekMorphology, values: Array(sanitized))
            }
        }

        let validWordLookup = Set(wordLookupDictionaries.map(\.name))
        let sanitizedDisabled = disabledWordLookupDictionaryNames.intersection(validWordLookup)
        if sanitizedDisabled != disabledWordLookupDictionaryNames {
            disabledWordLookupDictionaryNames = sanitizedDisabled
            store.setStringSet(.disabledWordLookupDictionaries, values: Array(sanitizedDisabled))
        }
    }

    /// Remove persisted modal-action IDs that no longer exist in Android arrays.xml contracts.
    private func sanitizeBookmarkModalActionPreferences(store: SettingsStore) {
        let validBibleActions = Set(Self.bibleBookmarkModalActionOptions.map(\.value))
        let sanitizedBible = disabledBibleBookmarkModalButtons.intersection(validBibleActions)
        if sanitizedBible != disabledBibleBookmarkModalButtons {
            disabledBibleBookmarkModalButtons = sanitizedBible
            store.setStringSet(.disableBibleBookmarkModalButtons, values: Array(sanitizedBible))
        }

        let validGenActions = Set(Self.genBookmarkModalActionOptions.map(\.value))
        let sanitizedGen = disabledGenBookmarkModalButtons.intersection(validGenActions)
        if sanitizedGen != disabledGenBookmarkModalButtons {
            disabledGenBookmarkModalButtons = sanitizedGen
            store.setStringSet(.disableGenBookmarkModalButtons, values: Array(sanitizedGen))
        }
    }

    /// Remove persisted experimental feature IDs that no longer exist in Android arrays.xml.
    private func sanitizeExperimentalFeatures(store: SettingsStore) {
        let validValues = Set(Self.experimentalFeatureOptions.map(\.value))
        let sanitized = enabledExperimentalFeatures.intersection(validValues)
        if sanitized != enabledExperimentalFeatures {
            enabledExperimentalFeatures = sanitized
            store.setStringSet(.experimentalFeatures, values: Array(sanitized))
        }
    }

    /// Normalizes stored night-mode values to one of the currently supported picker options.
    private static func nightModePickerSelection(from rawValue: String) -> String {
        if NightModeSettingsResolver.availableModes.contains(where: { $0.rawValue == rawValue }) {
            return rawValue
        }
        if rawValue == NightModeSetting.automatic.rawValue && !NightModeSettingsResolver.autoModeAvailable {
            return NightModeSetting.manual.rawValue
        }
        return NightModeSetting.system.rawValue
    }

    /// Normalizes persisted swipe-mode values to the Android contract supported by iOS.
    private static func normalizedBibleViewSwipeMode(_ rawValue: String) -> String {
        switch rawValue {
        case "CHAPTER", "PAGE", "NONE":
            return rawValue
        default:
            return "CHAPTER"
        }
    }

    /// Normalizes persisted toolbar-button action values to supported Android-parity modes.
    private static func normalizedToolbarButtonActionsMode(_ rawValue: String) -> String {
        switch rawValue {
        case "default", "swap-menu", "swap-activity":
            return rawValue
        default:
            return "default"
        }
    }

    /**
     Normalizes one persisted locale string against the supported Android parity values.

     - Parameter value: Raw locale value read from persistence.
     - Returns: The supported locale value when recognized, or the default empty value otherwise.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func normalizedLocalePrefValue(_ value: String) -> String {
        localeOptions.contains(where: { $0.value == value }) ? value : ""
    }

    /// Localized title for one night-mode option exposed by the settings picker.
    private static func nightModeModeTitle(_ mode: NightModeSetting) -> String {
        switch mode {
        case .system:
            return String(localized: "prefs_night_mode_system", defaultValue: "System")
        case .automatic:
            return String(localized: "prefs_night_mode_automatic", defaultValue: "Automatic")
        case .manual:
            return String(localized: "prefs_night_mode_manual", defaultValue: "Manual")
        }
    }

    /// Localized label for one locale picker option with English fallback behavior.
    private static func localizedLocaleOptionLabel(_ option: LocaleOption) -> String {
        let localized = String(localized: String.LocalizationValue(option.labelKey))
        return localized == option.labelKey ? option.labelDefault : localized
    }

    /// Localized title for one experimental feature option with English fallback behavior.
    fileprivate static func localizedExperimentalFeatureTitle(_ option: ExperimentalFeatureOption) -> String {
        let localized = String(localized: String.LocalizationValue(option.titleKey))
        return localized == option.titleKey ? option.titleDefault : localized
    }

    /// Localized title for one bookmark modal action option with English fallback behavior.
    fileprivate static func localizedBookmarkModalActionTitle(_ option: BookmarkModalActionOption) -> String {
        let localized = String(localized: String.LocalizationValue(option.titleKey))
        return localized == option.titleKey ? option.titleDefault : localized
    }

    /**
     Maps Android `locale_pref` values to the closest Apple language override value.
     */
    private static func appleLanguageCode(forLocalePrefValue value: String) -> String? {
        switch value {
        case "":
            return nil
        case "iw":
            return "he"
        case "in":
            return "id"
        case "zh-Hant-TW":
            return "zh-Hant"
        case "zh-Hans-CN":
            return "zh-Hans"
        default:
            return value
        }
    }

    /**
     Maps legacy Apple language overrides back to Android-aligned `locale_pref` values.
     */
    private static func localePrefValue(forAppleLanguage appleLanguage: String) -> String? {
        let normalized = appleLanguage.replacingOccurrences(of: "_", with: "-")
        let directValues = Set(localeOptions.map(\.value))
        if directValues.contains(normalized) {
            return normalized
        }
        switch normalized {
        case "he", "iw":
            return "iw"
        case "id", "in":
            return "in"
        default:
            if normalized.hasPrefix("zh-Hant") {
                return "zh-Hant-TW"
            }
            if normalized.hasPrefix("zh-Hans") {
                return "zh-Hans-CN"
            }
            if let base = normalized.split(separator: "-").first.map(String.init),
               directValues.contains(base) {
                return base
            }
            return nil
        }
    }
}

/**
 Multi-select dictionary picker for preferences where an empty selection means "all dictionaries".
 */
private struct DictionaryMultiSelectView: View {
    /// Navigation title for the picker sheet.
    let title: String

    /// Installed dictionary modules shown as toggle rows.
    let dictionaries: [ModuleInfo]

    /// Explicitly selected dictionary names. Empty means "all enabled".
    @Binding var selectedNames: Set<String>

    /// Builds the dictionary toggle list.
    var body: some View {
        List(dictionaries, id: \.name) { dictionary in
            Toggle(
                isOn: Binding(
                    get: {
                        selectedNames.isEmpty || selectedNames.contains(dictionary.name)
                    },
                    set: { isEnabled in
                        updateSelection(dictionaryName: dictionary.name, isEnabled: isEnabled)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictionary.name)
                    Text(dictionary.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
    }

    /**
     Applies one dictionary toggle change while preserving empty-means-all semantics.
     */
    private func updateSelection(dictionaryName: String, isEnabled: Bool) {
        let allNames = Set(dictionaries.map(\.name))
        var effectiveSelected = selectedNames.isEmpty ? allNames : selectedNames

        if isEnabled {
            effectiveSelected.insert(dictionaryName)
        } else {
            effectiveSelected.remove(dictionaryName)
        }

        if effectiveSelected == allNames {
            selectedNames = []
        } else {
            selectedNames = effectiveSelected
        }
    }
}

/**
 Inverse-selection dictionary picker for preferences where the stored set represents disabled items.
 */
private struct DictionaryInverseMultiSelectView: View {
    /// Navigation title for the picker sheet.
    let title: String

    /// Installed dictionary modules shown as toggle rows.
    let dictionaries: [ModuleInfo]

    /// Persisted dictionary names that should be disabled.
    @Binding var disabledNames: Set<String>

    /// Builds the inverse-selection dictionary toggle list.
    var body: some View {
        List(dictionaries, id: \.name) { dictionary in
            Toggle(
                isOn: Binding(
                    get: { !disabledNames.contains(dictionary.name) },
                    set: { isEnabled in
                        if isEnabled {
                            disabledNames.remove(dictionary.name)
                        } else {
                            disabledNames.insert(dictionary.name)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dictionary.name)
                    Text(dictionary.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
    }
}

/**
 Multi-select picker for enabling Android-parity experimental feature flags.
 */
private struct ExperimentalFeaturesMultiSelectView: View {
    /// Navigation title for the picker sheet.
    let title: String

    /// Available feature options derived from the Android contract.
    let options: [SettingsView.ExperimentalFeatureOption]

    /// Persisted set of enabled experimental feature identifiers.
    @Binding var selectedValues: Set<String>

    /// Builds the experimental-features toggle list.
    var body: some View {
        List(options) { option in
            Toggle(
                isOn: Binding(
                    get: { selectedValues.contains(option.value) },
                    set: { isEnabled in
                        if isEnabled {
                            selectedValues.insert(option.value)
                        } else {
                            selectedValues.remove(option.value)
                        }
                    }
                )
            ) {
                Text(SettingsView.localizedExperimentalFeatureTitle(option))
            }
        }
        .navigationTitle(title)
    }
}

/**
 Inverse-selection picker for bookmark modal actions where unchecked rows are hidden from the modal.
 */
private struct BookmarkModalActionsInverseMultiSelectView: View {
    /// Navigation title for the picker sheet.
    let title: String

    /// Available action options derived from the Android arrays.xml contract.
    let options: [SettingsView.BookmarkModalActionOption]

    /// Persisted set of disabled action identifiers.
    @Binding var disabledValues: Set<String>

    /// Builds the bookmark-modal action toggle list.
    var body: some View {
        List(options) { option in
            Toggle(
                isOn: Binding(
                    get: { !disabledValues.contains(option.value) },
                    set: { isEnabled in
                        if isEnabled {
                            disabledValues.remove(option.value)
                        } else {
                            disabledValues.insert(option.value)
                        }
                    }
                )
            ) {
                Text(SettingsView.localizedBookmarkModalActionTitle(option))
            }
        }
        .navigationTitle(title)
    }
}
