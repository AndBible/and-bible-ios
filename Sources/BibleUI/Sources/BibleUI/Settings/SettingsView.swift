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

 The view mixes direct global `TextDisplaySettings` bindings with persisted Android-parity
 preferences stored through `SettingsStore` and `UserDefaults`-backed `AppStorage`.

 Data dependencies:
 - `modelContext` is used to load and persist Android-parity settings through `SettingsStore`
 - `displaySettings`, `nightMode`, and `nightModeMode` are shared global settings owned by the parent
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

    /// Shared global text-display settings edited by nested settings screens.
    @Binding var displaySettings: TextDisplaySettings

    /// Shared effective night-mode state used by the reader.
    @Binding var nightMode: Bool

    /// Shared persisted night-mode switching mode (`system`, `manual`, or `automatic`).
    @Binding var nightModeMode: String

    /// Callback invoked when settings mutations should trigger reader refreshes.
    var onSettingsChanged: (() -> Void)?

    /// Reader controller used by feature shortcuts that edit pane-backed reading-progress settings.
    let readingProgressController: BibleReaderController?

    /// Current settings search query.
    @State private var settingsSearchText = ""

    /// Controls the confirmation prompt for resetting application preferences.
    @State private var showResetConfirmation = false

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
       - readingProgressController: Optional reader controller used by Reading Progress Settings.
       - onSettingsChanged: Optional callback invoked when changes should refresh reader content.
     */
    public init(
        displaySettings: Binding<TextDisplaySettings>,
        nightMode: Binding<Bool>,
        nightModeMode: Binding<String>,
        readingProgressController: BibleReaderController? = nil,
        onSettingsChanged: (() -> Void)? = nil
    ) {
        self._displaySettings = displaySettings
        self._nightMode = nightMode
        self._nightModeMode = nightModeMode
        self.readingProgressController = readingProgressController
        self.onSettingsChanged = onSettingsChanged
    }

    /**
     Builds the full settings form, preference hydration, alerts, and settings-side effects.
     */
    public var body: some View {
        settingsFormWithPreferencePersistence
    }

    /**
     Composes the visible settings sections without presentation modifiers or persistence observers.

     Keeping this as a small builder gives SwiftUI a stable root expression and keeps search gating
     declarative at the section level.
     *
     - Side Effects: none directly; child controls perform their own preference writes.
     - Failure Modes: Sections omitted by search or missing data are simply not rendered.
     */
    @ViewBuilder
    private var settingsForm: some View {
        Form {
            if shouldShowFeaturesSection {
                featuresSettingsSection
            }

            if shouldShowDictionarySection {
                dictionarySettingsSection
            }

            if shouldShowBehaviorSection {
                behaviorSettingsSection
            }

            if shouldShowLookAndFeelSection {
                lookAndFeelSection
            }

            if shouldShowSecuritySection {
                securitySettingsSection
            }

            if shouldShowAdvancedSection {
                advancedSettingsSection
            }

            if shouldShowAboutSection {
                aboutSettingsSection
            }

            if shouldShowNoSettingsSearchResults {
                noSettingsSearchResultsSection
            }
        }
    }

    /**
     Applies navigation, alerts, sheet presentation, search, and toolbar controls to the form.

     - Side Effects: `onAppear` reloads persisted state; toolbar and alerts mutate local presentation
       state and reset preferences when confirmed.
     - Failure Modes: Reset uses registry-backed defaults and falls back through `SettingsStore`.
     */
    private var settingsFormWithPresentation: some View {
        settingsForm
            .accessibilityIdentifier("settingsForm")
            .accessibilityValue(settingsAccessibilityValue)
            .navigationTitle(settingsNavigationTitleText)
            .alert(
                languageRestartAlertTitleText,
                isPresented: $showRestartAlert
            ) {
                Button(String(localized: "ok")) {}
            } message: {
                Text(languageRestartAlertMessageText)
            }
            .alert(
                settingsResetTitleText,
                isPresented: $showResetConfirmation
            ) {
                Button(String(localized: "cancel"), role: .cancel) {}
                Button(String(localized: "reset", defaultValue: "Reset"), role: .destructive) {
                    resetApplicationPreferences()
                }
            } message: {
                Text(settingsResetMessageText)
            }
            .sheet(isPresented: $showDiscreteHelp) {
                discreteHelpSheetContent
            }
            .searchable(
                text: $settingsSearchText,
                prompt: settingsSearchPromptText
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    settingsResetToolbarButton
                }
            }
            .onAppear {
                loadSettingsState()
            }
    }

    /**
     Adds persistence observers for multi-select settings whose state is edited in child screens.

     - Side Effects: Writes selected dictionary/action/experimental-feature values into SwiftData and
       refreshes reader content for options that affect rendered documents.
     - Failure Modes: Store writes use the same `SettingsStore` defaults and model-context error
       handling as the rest of settings.
     */
    private var settingsFormWithPreferencePersistence: some View {
        settingsFormWithPresentation
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

    /**
     Builds the module-backed dictionary settings section when relevant dictionaries are installed.

     - Side Effects: Navigation destinations mutate the bound dictionary-selection state; persistence is
       handled by the parent view's `onChange` observers.
     - Failure Modes: Empty module lists omit their rows instead of rendering disabled placeholders.
     */
    @ViewBuilder
    private var dictionarySettingsSection: some View {
        Section {
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
                        preferenceKey: .strongsGreekDictionary,
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
                        preferenceKey: .strongsHebrewDictionary,
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
                        preferenceKey: .robinsonGreekMorphology,
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
                        preferenceKey: .disabledWordLookupDictionaries,
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
        } header: {
            settingsSectionHeader(String(localized: "settings_dictionaries"))
        }
    }

    /**
     Builds Android-parity behavior preferences backed by `SettingsStore` and reader callbacks.

     - Side Effects: Writes changed values to SwiftData-backed preferences and refreshes reader content
       for display-affecting options.
     - Failure Modes: Store read/write helpers fall back to registry defaults if no persisted value exists.
     */
    @ViewBuilder
    private var behaviorSettingsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { navigateToVerse },
                set: { newValue in
                    navigateToVerse = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.navigateToVersePref, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .navigateToVersePref,
                    title: String(
                        localized: "prefs_navigate_to_verse_title",
                        defaultValue: "Navigate to verse"
                    ),
                    summary: String(
                        localized: "prefs_navigate_to_verse_summary",
                        defaultValue: "Choose verse (and chapter) when selecting a passage"
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { openLinksInSpecialWindow },
                set: { newValue in
                    openLinksInSpecialWindow = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.openLinksInSpecialWindowPref, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .openLinksInSpecialWindowPref,
                    title: String(
                        localized: "prefs_open_links_in_special_window_title",
                        defaultValue: "Links window"
                    ),
                    summary: String(
                        localized: "prefs_open_links_in_special_window_summary",
                        defaultValue: "Open links in special window, for quicker display of cross-references and Strongs"
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { screenKeepOn },
                set: { newValue in
                    screenKeepOn = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.screenKeepOnPref, value: newValue)
                    applyScreenKeepOn(newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .screenKeepOnPref,
                    title: String(localized: "prefs_screen_keep_on_title", defaultValue: "Keep screen on"),
                    summary: String(
                        localized: "prefs_screen_keep_on_summary",
                        defaultValue: "Prevent screen sleeping while using this app"
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { doubleTapToFullscreen },
                set: { newValue in
                    doubleTapToFullscreen = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.doubleTapToFullscreen, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .doubleTapToFullscreen,
                    title: String(
                        localized: "prefs_double_tap_to_fullscreen_title",
                        defaultValue: "Double-tap to Fullscreen"
                    ),
                    summary: String(
                        localized: "prefs_double_tap_to_fullscreen_summary",
                        defaultValue: "Enter fullscreen mode by double-tapping window"
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { autoFullscreen },
                set: { newValue in
                    autoFullscreen = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.autoFullscreenPref, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .autoFullscreenPref,
                    title: String(localized: "auto_fullscreen", defaultValue: "Fullscreen by scrolling"),
                    summary: String(
                        localized: "auto_fullscreen_summary",
                        defaultValue: "Switch automatically to fullscreen when scrolling text. Tip: you can always also switch to full screen by doubletapping screen."
                    )
                )
            }
            Picker(selection: Binding(
                    get: { Self.normalizedToolbarButtonActionsMode(toolbarButtonActionsMode) },
                    set: { newValue in
                        toolbarButtonActionsMode = Self.normalizedToolbarButtonActionsMode(newValue)
                        let store = SettingsStore(modelContext: modelContext)
                        store.setString(.toolbarButtonActions, value: toolbarButtonActionsMode)
                    }
                )) {
                Text(String(localized: "prefs_toolbar_button_action_default", defaultValue: "Default"))
                    .tag("default")
                Text(String(localized: "prefs_toolbar_button_action_swap_menu", defaultValue: "Swap menu"))
                    .tag("swap-menu")
                Text(String(localized: "prefs_toolbar_button_action_swap_activity", defaultValue: "Swap activity"))
                    .tag("swap-activity")
            } label: {
                settingsRowLabel(
                    preferenceKey: .toolbarButtonActions,
                    title: String(
                        localized: "prefs_toolbar_button_action_title",
                        defaultValue: "Bible/commentary toolbar button action"
                    ),
                    summary: String(
                        localized: "prefs_toolbar_button_action_summary",
                        defaultValue: "Choose if one-tap of Bible/commentary toolbar buttons shows menu or activity directly."
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { disableTwoStepBookmarking },
                set: { newValue in
                    disableTwoStepBookmarking = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.disableTwoStepBookmarking, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .disableTwoStepBookmarking,
                    title: String(
                        localized: "prefs_disable_two_step_bookmarking_title",
                        defaultValue: "One-step bookmarking"
                    ),
                    summary: String(
                        localized: "prefs_disable_two_step_bookmarking_summary",
                        defaultValue: "Show \"Selection\" and \"Verses\" items directly in Bible view Selection menu"
                    )
                )
            }
            Picker(selection: Binding(
                    get: { Self.normalizedBibleViewSwipeMode(bibleViewSwipeMode) },
                    set: { newValue in
                        bibleViewSwipeMode = Self.normalizedBibleViewSwipeMode(newValue)
                        let store = SettingsStore(modelContext: modelContext)
                        store.setString(.bibleViewSwipeMode, value: bibleViewSwipeMode)
                    }
            )) {
                Text(String(localized: "prefs_swipe_mode_chapter", defaultValue: "Chapter"))
                    .tag("CHAPTER")
                Text(String(localized: "prefs_swipe_mode_page", defaultValue: "Page"))
                    .tag("PAGE")
                Text(String(localized: "prefs_swipe_mode_none", defaultValue: "None"))
                    .tag("NONE")
            } label: {
                bibleViewSwipeModeSettingsRow
            }
            Toggle(isOn: Binding(
                get: { volumeKeysScroll },
                set: { newValue in
                    volumeKeysScroll = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.volumeKeysScroll, value: newValue)
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .volumeKeysScroll,
                    title: String(
                        localized: "prefs_volume_keys_scroll_title",
                        defaultValue: "Volume buttons scroll"
                    ),
                    summary: String(
                        localized: "prefs_volume_keys_scroll_summary",
                        defaultValue: "Use volume up/down to scroll Bible text"
                    ),
                    detail: String(
                        localized: "prefs_volume_keys_scroll_ios_note",
                        defaultValue: "iOS does not expose volume-button presses to apps. This setting is kept for Android parity and cross-device sync."
                    )
                )
            }
            Toggle(isOn: Binding(
                get: { displaySettings.enableVerseSelection ?? true },
                set: {
                    displaySettings.enableVerseSelection = $0
                    onSettingsChanged?()
                }
            )) {
                settingsRowLabel(
                    preferenceKey: nil,
                    title: String(localized: "verse_selection")
                )
            }
        } header: {
            settingsSectionHeader(
                String(localized: "prefs_behavior_customization_cat", defaultValue: "Application behavior")
            )
        }
    }

    /**
     Builds the discrete-mode security section.

     - Side Effects: Updates local security state; `calculatorPin` filtering strips non-numeric input.
     - Failure Modes: Invalid PIN characters are ignored rather than persisted.
     */
    @ViewBuilder
    private var securitySettingsSection: some View {
        Section {
            Button {
                showDiscreteHelp = true
            } label: {
                settingsRowLabel(
                    preferenceKey: .discreteHelp,
                    title: String(localized: "discrete_help_title"),
                    summary: String(localized: "discrete_help_summary")
                )
            }

            Toggle(isOn: $discreteMode) {
                settingsRowLabel(
                    preferenceKey: .discreteMode,
                    title: String(localized: "discrete_mode"),
                    summary: String(localized: "discrete_mode_description")
                )
            }

            Toggle(isOn: $showCalculator) {
                settingsRowLabel(
                    preferenceKey: .showCalculator,
                    title: String(localized: "show_calculator"),
                    summary: String(localized: "show_calculator_description")
                )
            }

            HStack(alignment: .top, spacing: 12) {
                settingsRowLabel(
                    preferenceKey: .calculatorPin,
                    title: String(localized: "calculator_pin"),
                    summary: String(localized: "calculator_pin_description")
                )
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
        } header: {
            settingsSectionHeader(String(localized: "settings_security"))
        }
    }

    /**
     Builds advanced preferences and debug-only action rows.

     - Side Effects: Writes advanced preferences through `SettingsStore`, can open system settings on
       iOS, and can schedule a debug crash in DEBUG builds.
     - Failure Modes: Debug-only actions are omitted from release builds.
     */
    @ViewBuilder
    private var advancedSettingsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { enableBluetoothMediaButtons },
                set: { newValue in
                    enableBluetoothMediaButtons = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.enableBluetoothPref, value: newValue)
                    onSettingsChanged?()
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .enableBluetoothPref,
                    title: String(
                        localized: "prefs_enable_bluetooth_title",
                        defaultValue: "Enable Bluetooth media buttons"
                    ),
                    summary: String(
                        localized: "prefs_enable_bluetooth_summary",
                        defaultValue: "Handle Bluetooth media buttons to start/stop speaking."
                    )
                )
            }
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
                    preferenceKey: .experimentalFeatures,
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
            Toggle(isOn: Binding(
                get: { showErrorBox },
                set: { newValue in
                    showErrorBox = newValue
                    let store = SettingsStore(modelContext: modelContext)
                    store.setBool(.showErrorBox, value: newValue)
                    onSettingsChanged?()
                }
            )) {
                settingsRowLabel(
                    preferenceKey: .showErrorBox,
                    title: String(
                        localized: "prefs_show_error_box_title",
                        defaultValue: "Show Javascript error box"
                    ),
                    summary: String(
                        localized: "prefs_show_error_box_summary",
                        defaultValue: "Useful for developers when debugging BibleView javascript side errors. This will make the app slower."
                    )
                )
            }
            #endif

            #if os(iOS)
            Button {
                openBibleLinkSystemSettings()
            } label: {
                settingsRowLabel(
                    preferenceKey: .openLinks,
                    title: String(
                        localized: "open_bible_links_title",
                        defaultValue: "Open Bible links in AndBible"
                    ),
                    summary: String(
                        localized: "open_bible_links_summary",
                        defaultValue: "When clicking links that refer to AndBible supported Bible URL, open them in AndBible"
                    )
                )
            }
            #endif

            #if DEBUG
            Button(role: .destructive) {
                triggerDebugCrash()
            } label: {
                settingsRowLabel(
                    preferenceKey: .crashApp,
                    title: String(
                        localized: "crash_app",
                        defaultValue: "Crash app!"
                    ),
                    summary: debugCrashScheduled
                        ? String(
                            localized: "crash_app_scheduled_summary",
                            defaultValue: "Crash scheduled in 10 seconds."
                        )
                        : String(
                            localized: "crash_app_summary",
                            defaultValue: "Crash app after 10 seconds. Debugging feature, visible only in debug builds."
                        ),
                    isEnabled: !debugCrashScheduled
                )
            }
            .disabled(debugCrashScheduled)
            #endif
        } header: {
            settingsSectionHeader(
                String(localized: "prefs_advanced_settings_cat", defaultValue: "Advanced settings")
            )
        }
    }

    /**
     Builds the static about/version section.

     - Side Effects: none.
     - Failure Modes: none.
     */
    @ViewBuilder
    private var aboutSettingsSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                settingsRowLabel(
                    preferenceKey: nil,
                    title: String(localized: "version")
                )
                Spacer()
                Text(AndBibleAppVersionMetadata.current().detailText)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        } header: {
            settingsSectionHeader(String(localized: "settings_about"))
        }
    }

    /**
     Builds the empty-search-results section shown only for active queries with no matches.

     - Side Effects: none.
     - Failure Modes: none.
     */
    @ViewBuilder
    private var noSettingsSearchResultsSection: some View {
        Section {
            Text(String(localized: "settings_search_no_results", defaultValue: "No settings found"))
                .foregroundStyle(.secondary)
        }
    }

    /**
     Builds the "Look & feel" section, including nested display editors and appearance toggles.
     */
    @ViewBuilder
    private var lookAndFeelSection: some View {
        Section {
            settingsNavigationLink(
                title: String(localized: "settings_text_display"),
                androidKey: "global_text_display_settings",
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
            Picker(selection: Binding(
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
                )) {
                ForEach(NightModeSettingsResolver.availableModes, id: \.rawValue) { mode in
                    Text(Self.nightModeModeTitle(mode)).tag(mode.rawValue)
                }
            } label: {
                settingsRowLabel(
                    preferenceKey: .nightModePref3,
                    title: String(localized: "prefs_night_mode_title", defaultValue: "Night mode switching"),
                    summary: String(
                        localized: "prefs_night_mode_summary",
                        defaultValue: "Whether to switch to night mode manually or via system setting. Manual switching can be done from the 3-dot options menu on the main screen."
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { monochromeMode },
                    set: { newValue in
                        monochromeMode = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.monochromeMode, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .monochromeMode,
                    title: String(localized: "prefs_e_ink_mode_title", defaultValue: "Black & white mode"),
                    summary: String(
                        localized: "prefs_eink_mode_summary",
                        defaultValue: "Use application in monochrome mode (no colors), making it more suitable for E-ink devices."
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { disableAnimations },
                    set: { newValue in
                        disableAnimations = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.disableAnimations, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .disableAnimations,
                    title: String(localized: "prefs_disable_animations_title", defaultValue: "Disable animations"),
                    summary: String(
                        localized: "prefs_disable_animations_summary",
                        defaultValue: "Disable various animations such as smooth scrolling."
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { disableClickToEdit },
                    set: { newValue in
                        disableClickToEdit = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.disableClickToEdit, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .disableClickToEdit,
                    title: String(
                        localized: "prefs_disable_click_to_edit_title",
                        defaultValue: "Disable Study Pad click-to-edit"
                    ),
                    summary: String(
                        localized: "prefs_disable_click_to_edit_summary",
                        defaultValue: "Requires using the edit button to edit notes in the Study Pad."
                    )
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                settingsRowLabel(
                    preferenceKey: .fontSizeMultiplier,
                    title: String(
                        localized: "pref_font_size_multiplier_title",
                        defaultValue: "Font size multiplier"
                    ),
                    summary: String(
                        format: String(
                            localized: "prefs_font_size_multiplier_summary",
                            defaultValue: "Multiply text font sizes by this number. Current value: %.1fx"
                        ),
                        Double(fontSizeMultiplier) / 100.0
                    )
                )
                Slider(
                    value: Binding(
                        get: { Double(fontSizeMultiplier) },
                        set: { newValue in
                            let roundedValue = Int((newValue / 10.0).rounded() * 10.0)
                            fontSizeMultiplier = min(max(roundedValue, 10), 500)
                            let store = SettingsStore(modelContext: modelContext)
                            store.setInt(.fontSizeMultiplier, value: fontSizeMultiplier)
                            onSettingsChanged?()
                        }
                    ),
                    in: 10...500,
                    step: 10
                )
                .padding(.leading, 66)
            }
            Toggle(isOn: Binding(
                    get: { fullScreenHideButtons },
                    set: { newValue in
                        fullScreenHideButtons = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.fullScreenHideButtonsPref, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .fullScreenHideButtonsPref,
                    title: String(
                        localized: "full_screen_hide_buttons_pref_title",
                        defaultValue: "Hide window button bar in fullscreen"
                    ),
                    summary: String(
                        localized: "full_screen_hide_buttons_pref_summary",
                        defaultValue: "When switching to fullscreen mode, hide automatically window button bar that is on the bottom of the screen"
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { hideWindowButtons },
                    set: { newValue in
                        hideWindowButtons = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.hideWindowButtons, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .hideWindowButtons,
                    title: String(
                        localized: "hide_window_buttons_title",
                        defaultValue: "Hide window buttons"
                    ),
                    summary: String(
                        localized: "hide_window_buttons_summary",
                        defaultValue: "Window buttons that are displayed on right side of the Bible views are hidden. Window navigation bar on the bottom is still displayed and you may open window popup menu by long-clicking them."
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { hideBibleReferenceOverlay },
                    set: { newValue in
                        hideBibleReferenceOverlay = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.hideBibleReferenceOverlay, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .hideBibleReferenceOverlay,
                    title: String(
                        localized: "hide_bible_reference_overlay_title",
                        defaultValue: "Hide Bible reference overlay"
                    ),
                    summary: String(
                        localized: "hide_bible_reference_overlay_summary",
                        defaultValue: "Do not show the semi-transparent Bible reference overlay when app is in fullscreen mode"
                    )
                )
            }
            Toggle(isOn: Binding(
                    get: { showActiveWindowIndicator },
                    set: { newValue in
                        showActiveWindowIndicator = newValue
                        let store = SettingsStore(modelContext: modelContext)
                        store.setBool(.showActiveWindowIndicator, value: newValue)
                        onSettingsChanged?()
                    }
                )) {
                settingsRowLabel(
                    preferenceKey: .showActiveWindowIndicator,
                    title: String(
                        localized: "active_window_indicator_title",
                        defaultValue: "Show active window indicator"
                    ),
                    summary: String(
                        localized: "active_window_indicator_summary",
                        defaultValue: "Highlight window corners to help recognising which window is active"
                    )
                )
            }
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
                    preferenceKey: .disableBibleBookmarkModalButtons,
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
                    preferenceKey: .disableGenBookmarkModalButtons,
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
            Picker(selection: $selectedLanguage) {
                ForEach(Self.localeOptions) { lang in
                    Text(Self.localizedLocaleOptionLabel(lang)).tag(lang.value)
                }
            } label: {
                settingsRowLabel(
                    preferenceKey: .localePref,
                    title: String(localized: "prefs_interface_locale_title", defaultValue: "Application language"),
                    summary: String(
                        localized: "prefs_interface_locale_summary",
                        defaultValue: "Select custom user interface language"
                    ),
                    detail: String(localized: "language_restart_required")
                )
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
                showRestartAlert = true
            }
        } header: {
            settingsSectionHeader(String(localized: "prefs_display_customization_cat", defaultValue: "Look & feel"))
        }
    }

    /// Whether any module-backed dictionary preference sections should be shown.
    private var hasDictionaryPreferences: Bool {
        !strongsGreekDictionaries.isEmpty ||
            !strongsHebrewDictionaries.isEmpty ||
            !robinsonMorphologyDictionaries.isEmpty ||
            !wordLookupDictionaries.isEmpty
    }

    /// Whether the module-backed dictionary section should render for the current search state.
    private var shouldShowDictionarySection: Bool {
        hasDictionaryPreferences && settingsSearchMatchesSection(dictionarySettingsSearchEntries)
    }

    /// Whether the behavior section should render for the current search state.
    private var shouldShowBehaviorSection: Bool {
        settingsSearchMatchesSection(behaviorSettingsSearchEntries)
    }

    /// Whether the look-and-feel section should render for the current search state.
    private var shouldShowLookAndFeelSection: Bool {
        settingsSearchMatchesSection(lookAndFeelSettingsSearchEntries)
    }

    /// Whether the security section should render for the current search state.
    private var shouldShowSecuritySection: Bool {
        settingsSearchMatchesSection(securitySettingsSearchEntries)
    }

    /// Whether the advanced section should render for the current search state.
    private var shouldShowAdvancedSection: Bool {
        settingsSearchMatchesSection(advancedSettingsSearchEntries)
    }

    /// Whether the about section should render for the current search state.
    private var shouldShowAboutSection: Bool {
        settingsSearchMatchesSection(aboutSettingsSearchEntries)
    }

    /// Extracted swipe-mode picker label that keeps the main settings form type-checkable.
    private var bibleViewSwipeModeSettingsRow: AndBibleSettingsRowLabel {
        settingsRowLabel(
            preferenceKey: .bibleViewSwipeMode,
            title: String(
                localized: "prefs_bible_view_swipe_mode_title",
                defaultValue: "Action for swipe left / right gesture"
            ),
            summary: String(
                localized: "prefs_bible_view_swipe_mode_summary",
                defaultValue: "Swipe left / right gesture can be used to go to next page / chapter."
            )
        )
    }

    /// Localized navigation title kept outside the main SwiftUI modifier chain.
    private var settingsNavigationTitleText: String {
        String(localized: "settings")
    }

    /// Localized restart-alert title kept outside the main SwiftUI modifier chain.
    private var languageRestartAlertTitleText: String {
        String(localized: "prefs_interface_locale_title", defaultValue: "Application language")
    }

    /// Localized restart-alert message kept outside the main SwiftUI modifier chain.
    private var languageRestartAlertMessageText: String {
        String(localized: "language_restart_required")
    }

    /// Localized reset-alert title kept outside the main SwiftUI modifier chain.
    private var settingsResetTitleText: String {
        String(localized: "settings_reset_title", defaultValue: "Reset settings")
    }

    /// Localized reset-alert message kept outside the main SwiftUI modifier chain.
    private var settingsResetMessageText: String {
        String(
            localized: "settings_reset_message",
            defaultValue: "Reset application preferences to their default values?"
        )
    }

    /// Localized search prompt kept outside the main SwiftUI modifier chain.
    private var settingsSearchPromptText: String {
        String(localized: "search", defaultValue: "Search")
    }

    /**
     Builds the toolbar reset action used by Application preferences.

     - Side Effects: Sets local confirmation state so the destructive reset runs only after the alert.
     - Failure Modes: none.
     */
    @ViewBuilder
    private var settingsResetToolbarButton: some View {
        Button {
            showResetConfirmation = true
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .accessibilityLabel(String(localized: "reset", defaultValue: "Reset"))
        .accessibilityIdentifier("settingsResetButton")
    }

    /**
     Builds the discrete-mode help sheet outside the main form expression.

     Splitting this sheet content keeps the large settings screen type-checkable while preserving
     the same modal behavior and toolbar dismissal.
     */
    @ViewBuilder
    private var discreteHelpSheetContent: some View {
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

    /**
     Builds Android's feature-shortcut section using native SwiftUI navigation.

     iOS implements the feature shortcuts that have real local destinations. The Android AI row is
     intentionally absent because this app has no AI settings contract to open.
     */
    @ViewBuilder
    private var featuresSettingsSection: some View {
        Section {
            let syncEntry = syncSettingsSearchEntry
            if settingsSearchMatchesEntry(syncEntry) {
                settingsNavigationLink(
                    title: syncEntry.title,
                    androidKey: "sync_settings_shortcut",
                    summary: syncEntry.summary,
                    accessibilityIdentifier: syncEntry.identifier
                ) {
                    SyncSettingsView()
                }
            }

            let readingProgressEntry = readingProgressSettingsSearchEntry
            if settingsSearchMatchesEntry(readingProgressEntry) {
                settingsNavigationLink(
                    title: readingProgressEntry.title,
                    androidKey: "reading_progress_settings_shortcut",
                    summary: readingProgressEntry.summary,
                    accessibilityIdentifier: readingProgressEntry.identifier
                ) {
                    ReadingProgressSettingsView(controller: readingProgressController)
                        .accessibilityIdentifier("readingProgressSettingsScreen")
                }
            }
        } header: {
            settingsSectionHeader(String(localized: "features", defaultValue: "Features"))
        }
    }

    /// Whether the current query should show the Android feature-shortcut section.
    private var shouldShowFeaturesSection: Bool {
        settingsSearchMatchesSection(featuresSettingsSearchEntries)
    }

    /// Search entry for the sync feature shortcut.
    private var syncSettingsSearchEntry: AndBibleSettingsSearchEntry {
        AndBibleSettingsSearchEntry(
            identifier: "settingsSyncLink",
            title: String(localized: "cloud_sync_title", defaultValue: "Device synchronization"),
            summary: String(localized: "icloud_sync_description"),
            keywords: ["features", "sync", "icloud", "cloud", "sync_settings_shortcut"]
        )
    }

    /// Search entry for the reading-progress feature shortcut.
    private var readingProgressSettingsSearchEntry: AndBibleSettingsSearchEntry {
        AndBibleSettingsSearchEntry(
            identifier: "settingsReadingProgressLink",
            title: String(localized: "reading_progress_settings", defaultValue: "Reading Progress Settings"),
            summary: String(
                localized: "reading_progress_settings_summary",
                defaultValue: "Configure automatic reading and memorization progress tracking."
            ),
            keywords: ["features", "reading", "progress", "memorization", "reading_progress_settings_shortcut"]
        )
    }

    /// Search entries for feature shortcuts that can be opened from Application preferences.
    private var featuresSettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [syncSettingsSearchEntry, readingProgressSettingsSearchEntry]
    }

    /// Search entries for module-backed dictionary preference rows currently visible on this device.
    private var dictionarySettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        var entries: [AndBibleSettingsSearchEntry] = []
        if !strongsGreekDictionaries.isEmpty {
            entries.append(
                .init(
                    identifier: "settingsStrongsGreekDictionaryLink",
                    title: String(
                        localized: "choose_strongs_greek_dictionary_title",
                        defaultValue: "Strongs Greek dictionary"
                    ),
                    summary: String(
                        localized: "choose_strongs_greek_dictionary_summary",
                        defaultValue: "Choose Strongs dictionary for Greek word definitions"
                    ),
                    keywords: ["dictionaries", AppPreferenceKey.strongsGreekDictionary.rawValue]
                )
            )
        }
        if !strongsHebrewDictionaries.isEmpty {
            entries.append(
                .init(
                    identifier: "settingsStrongsHebrewDictionaryLink",
                    title: String(
                        localized: "choose_strongs_hebrew_dictionary_title",
                        defaultValue: "Strongs Hebrew dictionary"
                    ),
                    summary: String(
                        localized: "choose_strongs_hebrew_dictionary_summary",
                        defaultValue: "Choose Strongs dictionary for Hebrew word definitions"
                    ),
                    keywords: ["dictionaries", AppPreferenceKey.strongsHebrewDictionary.rawValue]
                )
            )
        }
        if !robinsonMorphologyDictionaries.isEmpty {
            entries.append(
                .init(
                    identifier: "settingsRobinsonMorphologyLink",
                    title: String(
                        localized: "choose_strongs_greek_morphology_title",
                        defaultValue: "Robinson Greek morphology"
                    ),
                    summary: String(
                        localized: "choose_strongs_greek_morphology_summary",
                        defaultValue: "Choose dictionary for Robinson Greek morphology definitions"
                    ),
                    keywords: ["dictionaries", AppPreferenceKey.robinsonGreekMorphology.rawValue]
                )
            )
        }
        if !wordLookupDictionaries.isEmpty {
            entries.append(
                .init(
                    identifier: "settingsWordLookupDictionariesLink",
                    title: String(
                        localized: "choose_word_lookup_dictionary_title",
                        defaultValue: "Word lookup dictionaries"
                    ),
                    summary: String(
                        localized: "choose_word_lookup_dictionary_summary",
                        defaultValue: "Choose dictionaries for looking up words"
                    ),
                    keywords: ["dictionaries", AppPreferenceKey.disabledWordLookupDictionaries.rawValue]
                )
            )
        }
        return entries
    }

    /// Search entries for behavior preferences.
    private var behaviorSettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [
            preferenceSearchEntry(
                .navigateToVersePref,
                title: String(localized: "prefs_navigate_to_verse_title", defaultValue: "Navigate to verse"),
                summary: String(
                    localized: "prefs_navigate_to_verse_summary",
                    defaultValue: "Choose verse (and chapter) when selecting a passage"
                )
            ),
            preferenceSearchEntry(
                .openLinksInSpecialWindowPref,
                title: String(localized: "prefs_open_links_in_special_window_title", defaultValue: "Links window"),
                summary: String(
                    localized: "prefs_open_links_in_special_window_summary",
                    defaultValue: "Open links in special window, for quicker display of cross-references and Strongs"
                )
            ),
            preferenceSearchEntry(
                .screenKeepOnPref,
                title: String(localized: "prefs_screen_keep_on_title", defaultValue: "Keep screen on"),
                summary: String(
                    localized: "prefs_screen_keep_on_summary",
                    defaultValue: "Prevent screen sleeping while using this app"
                )
            ),
            preferenceSearchEntry(
                .doubleTapToFullscreen,
                title: String(localized: "prefs_double_tap_to_fullscreen_title", defaultValue: "Double-tap to Fullscreen"),
                summary: String(
                    localized: "prefs_double_tap_to_fullscreen_summary",
                    defaultValue: "Enter fullscreen mode by double-tapping window"
                )
            ),
            preferenceSearchEntry(
                .autoFullscreenPref,
                title: String(localized: "auto_fullscreen", defaultValue: "Fullscreen by scrolling"),
                summary: String(
                    localized: "auto_fullscreen_summary",
                    defaultValue: "Switch automatically to fullscreen when scrolling text. Tip: you can always also switch to full screen by doubletapping screen."
                )
            ),
            preferenceSearchEntry(
                .toolbarButtonActions,
                title: String(
                    localized: "prefs_toolbar_button_action_title",
                    defaultValue: "Bible/commentary toolbar button action"
                ),
                summary: String(
                    localized: "prefs_toolbar_button_action_summary",
                    defaultValue: "Choose if one-tap of Bible/commentary toolbar buttons shows menu or activity directly."
                )
            ),
            preferenceSearchEntry(
                .disableTwoStepBookmarking,
                title: String(
                    localized: "prefs_disable_two_step_bookmarking_title",
                    defaultValue: "One-step bookmarking"
                ),
                summary: String(
                    localized: "prefs_disable_two_step_bookmarking_summary",
                    defaultValue: "Show \"Selection\" and \"Verses\" items directly in Bible view Selection menu"
                )
            ),
            preferenceSearchEntry(
                .bibleViewSwipeMode,
                title: String(
                    localized: "prefs_bible_view_swipe_mode_title",
                    defaultValue: "Action for swipe left / right gesture"
                ),
                summary: String(
                    localized: "prefs_bible_view_swipe_mode_summary",
                    defaultValue: "Swipe left / right gesture can be used to go to next page / chapter."
                )
            ),
            preferenceSearchEntry(
                .volumeKeysScroll,
                title: String(localized: "prefs_volume_keys_scroll_title", defaultValue: "Volume buttons scroll"),
                summary: String(
                    localized: "prefs_volume_keys_scroll_summary",
                    defaultValue: "Use volume up/down to scroll Bible text"
                )
            ),
            .init(
                identifier: "settingsVerseSelection",
                title: String(localized: "verse_selection"),
                keywords: ["application behavior", "selection"]
            ),
        ]
    }

    /// Search entries for appearance and global text-display preferences.
    private var lookAndFeelSettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [
            .init(
                identifier: "settingsTextDisplayLink",
                title: String(localized: "settings_text_display"),
                keywords: ["look and feel", "display", "font", "text"]
            ),
            .init(
                identifier: "settingsColorsLink",
                title: String(localized: "settings_colors"),
                keywords: ["look and feel", "colors", "theme"]
            ),
            preferenceSearchEntry(
                .nightModePref3,
                title: String(localized: "prefs_night_mode_title", defaultValue: "Night mode switching"),
                summary: String(
                    localized: "prefs_night_mode_summary",
                    defaultValue: "Whether to switch to night mode manually or via system setting. Manual switching can be done from the 3-dot options menu on the main screen."
                )
            ),
            preferenceSearchEntry(
                .monochromeMode,
                title: String(localized: "prefs_e_ink_mode_title", defaultValue: "Black & white mode"),
                summary: String(
                    localized: "prefs_eink_mode_summary",
                    defaultValue: "Use application in monochrome mode (no colors), making it more suitable for E-ink devices."
                )
            ),
            preferenceSearchEntry(
                .disableAnimations,
                title: String(localized: "prefs_disable_animations_title", defaultValue: "Disable animations"),
                summary: String(
                    localized: "prefs_disable_animations_summary",
                    defaultValue: "Disable various animations such as smooth scrolling."
                )
            ),
            preferenceSearchEntry(
                .disableClickToEdit,
                title: String(
                    localized: "prefs_disable_click_to_edit_title",
                    defaultValue: "Disable Study Pad click-to-edit"
                ),
                summary: String(
                    localized: "prefs_disable_click_to_edit_summary",
                    defaultValue: "Requires using the edit button to edit notes in the Study Pad."
                )
            ),
            preferenceSearchEntry(
                .fontSizeMultiplier,
                title: String(localized: "pref_font_size_multiplier_title", defaultValue: "Font size multiplier")
            ),
            preferenceSearchEntry(
                .fullScreenHideButtonsPref,
                title: String(
                    localized: "full_screen_hide_buttons_pref_title",
                    defaultValue: "Hide window button bar in fullscreen"
                )
            ),
            preferenceSearchEntry(
                .hideWindowButtons,
                title: String(localized: "hide_window_buttons_title", defaultValue: "Hide window buttons")
            ),
            preferenceSearchEntry(
                .hideBibleReferenceOverlay,
                title: String(
                    localized: "hide_bible_reference_overlay_title",
                    defaultValue: "Hide Bible reference overlay"
                )
            ),
            preferenceSearchEntry(
                .showActiveWindowIndicator,
                title: String(
                    localized: "active_window_indicator_title",
                    defaultValue: "Show active window indicator"
                )
            ),
            preferenceSearchEntry(
                .disableBibleBookmarkModalButtons,
                title: String(
                    localized: "prefs_in_window_bible_bookmark_modal_buttons_title",
                    defaultValue: "One-tap actions (Bibles)"
                )
            ),
            preferenceSearchEntry(
                .disableGenBookmarkModalButtons,
                title: String(
                    localized: "prefs_in_window_gen_bookmark_modal_buttons_title",
                    defaultValue: "One-tap actions (Other)"
                )
            ),
            preferenceSearchEntry(
                .localePref,
                title: String(localized: "prefs_interface_locale_title", defaultValue: "Application language")
            ),
        ]
    }

    /// Search entries for security preferences.
    private var securitySettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [
            preferenceSearchEntry(
                .discreteHelp,
                title: String(localized: "discrete_help_title"),
                summary: String(localized: "discrete_help_summary")
            ),
            preferenceSearchEntry(
                .discreteMode,
                title: String(localized: "discrete_mode"),
                summary: String(localized: "discrete_mode_description")
            ),
            preferenceSearchEntry(
                .showCalculator,
                title: String(localized: "show_calculator"),
                summary: String(localized: "show_calculator_description")
            ),
            preferenceSearchEntry(
                .calculatorPin,
                title: String(localized: "calculator_pin"),
                summary: String(localized: "calculator_pin_description")
            ),
        ]
    }

    /// Search entries for advanced preferences and developer/debug action rows.
    private var advancedSettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [
            preferenceSearchEntry(
                .enableBluetoothPref,
                title: String(localized: "prefs_enable_bluetooth_title", defaultValue: "Enable Bluetooth media buttons"),
                summary: String(
                    localized: "prefs_enable_bluetooth_summary",
                    defaultValue: "Handle Bluetooth media buttons to start/stop speaking."
                )
            ),
            preferenceSearchEntry(
                .experimentalFeatures,
                title: String(localized: "prefs_experimental_features_title", defaultValue: "Experimental features"),
                summary: String(
                    localized: "prefs_experimental_features_summary",
                    defaultValue: "Select which experimental features to enable. These features are still in development and may change or be removed"
                )
            ),
            preferenceSearchEntry(
                .showErrorBox,
                title: String(localized: "prefs_show_error_box_title", defaultValue: "Show Javascript error box")
            ),
            preferenceSearchEntry(
                .openLinks,
                title: String(localized: "open_bible_links_title", defaultValue: "Open Bible links in AndBible")
            ),
            preferenceSearchEntry(
                .crashApp,
                title: String(localized: "crash_app", defaultValue: "Crash app!")
            ),
        ]
    }

    /// Search entry for static application information retained in Settings.
    private var aboutSettingsSearchEntries: [AndBibleSettingsSearchEntry] {
        [
            .init(
                identifier: "settingsVersion",
                title: String(localized: "version"),
                keywords: ["about", "application"]
            ),
        ]
    }

    /// Whether a non-empty query currently filters out every available settings section.
    private var shouldShowNoSettingsSearchResults: Bool {
        guard isSettingsSearchActive else {
            return false
        }
        return !shouldShowFeaturesSection &&
            !shouldShowDictionarySection &&
            !shouldShowBehaviorSection &&
            !shouldShowLookAndFeelSection &&
            !shouldShowSecuritySection &&
            !shouldShowAdvancedSection &&
            !shouldShowAboutSection
    }

    /// Whether the current search text contains at least one normalized term.
    private var isSettingsSearchActive: Bool {
        !AndBibleSettingsSearchMatcher.normalizedTerms(from: settingsSearchText).isEmpty
    }

    /**
     Creates one searchable entry from an Android parity preference key.

     - Parameters:
       - key: Registry key backing the row.
       - title: User-visible title.
       - summary: Optional row summary.
       - detail: Optional current-value detail.
       - keywords: Additional aliases for search.
     - Returns: A normalized settings search entry.
     - Side effects: none.
     - Failure modes: none.
     */
    private func preferenceSearchEntry(
        _ key: AppPreferenceKey,
        title: String,
        summary: String = "",
        detail: String = "",
        keywords: [String] = []
    ) -> AndBibleSettingsSearchEntry {
        AndBibleSettingsSearchEntry(
            identifier: key.rawValue,
            title: title,
            summary: summary,
            detail: detail,
            keywords: keywords + [key.rawValue]
        )
    }

    /**
     Returns whether a settings section should remain visible for the current query.

     - Parameter entries: Search entries represented by the section.
     - Returns: `true` for all sections when search is empty, otherwise `true` only when at least
       one row in the section matches every query term.
     - Side effects: none.
     - Failure modes: none.
     */
    private func settingsSearchMatchesSection(_ entries: [AndBibleSettingsSearchEntry]) -> Bool {
        guard isSettingsSearchActive else {
            return true
        }
        return entries.contains(where: settingsSearchMatchesEntry)
    }

    /**
     Returns whether one settings entry matches the current query.

     - Parameter entry: Candidate settings entry.
     - Returns: `true` when the entry should be visible.
     - Side effects: none.
     - Failure modes: none.
     */
    private func settingsSearchMatchesEntry(_ entry: AndBibleSettingsSearchEntry) -> Bool {
        AndBibleSettingsSearchMatcher.matches(query: settingsSearchText, entry: entry)
    }

    /**
     Builds the common title/summary/detail row used by selection-style settings links.
     */
    @ViewBuilder
    private func settingsSelectionRow(
        preferenceKey: AppPreferenceKey? = nil,
        title: String,
        summary: String,
        detail: String
    ) -> some View {
        settingsRowLabel(
            preferenceKey: preferenceKey,
            title: title,
            summary: summary,
            detail: detail
        )
    }

    /**
     Builds one Settings navigation row using the same `NavigationLink` semantics as production.
     *
     * This preserves the native list-row interaction model instead of routing navigation through
     * test-only state toggles.
     */
    @ViewBuilder
    private func settingsNavigationLink<Destination: View>(
        title: String,
        preferenceKey: AppPreferenceKey? = nil,
        androidKey: String? = nil,
        summary: String? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            settingsNavigationRow(
                title: title,
                preferenceKey: preferenceKey,
                androidKey: androidKey,
                summary: summary
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /**
     Builds a single-line navigation row used by nested settings links.
     *
     * - Parameter title: User-visible title shown in the row.
     * - Returns: Row content suitable for use as a `NavigationLink` label inside the settings form.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    @ViewBuilder
    private func settingsNavigationRow(
        title: String,
        preferenceKey: AppPreferenceKey? = nil,
        androidKey: String? = nil,
        summary: String? = nil
    ) -> some View {
        settingsRowLabel(
            preferenceKey: preferenceKey,
            androidKey: androidKey,
            title: title,
            summary: summary
        )
    }

    /**
     Builds one Android-shaped settings row label for native SwiftUI controls.

     - Parameters:
       - preferenceKey: Optional Android preference key used to resolve source icon metadata.
       - androidKey: Optional raw Android key for action rows not represented by `AppPreferenceKey`.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - isEnabled: Whether the row should render with enabled or disabled emphasis.
     - Returns: Shared row label aligned with Android preference geometry.
     - Side effects: Renders an image from the module bundle when `preferenceKey` has catalog metadata.
     - Failure modes: Unknown keys simply produce an un-iconed but aligned row.
     */
    private func settingsRowLabel(
        preferenceKey: AppPreferenceKey?,
        androidKey: String? = nil,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true
    ) -> AndBibleSettingsRowLabel {
        let icon = preferenceKey.flatMap { AndBibleIconCatalog.settingsIcon(forAndroidKey: $0.rawValue) } ??
            androidKey.flatMap { AndBibleIconCatalog.settingsIcon(forAndroidKey: $0) }
        return AndBibleSettingsRowLabel(
            title: title,
            summary: summary,
            detail: detail,
            icon: icon,
            isEnabled: isEnabled
        )
    }

    /**
     Builds one Android-shaped settings row label for action rows backed by raw Android keys.

     - Parameters:
       - androidKey: Raw Android preference/action key used to resolve source icon metadata.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - isEnabled: Whether the row should render with enabled or disabled emphasis.
     - Returns: Shared row label aligned with Android preference geometry.
     - Side effects: Renders an image from the module bundle when `androidKey` has catalog metadata.
     - Failure modes: Unknown keys simply produce an un-iconed but aligned row.
     */
    private func settingsRowLabel(
        androidKey: String,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true
    ) -> AndBibleSettingsRowLabel {
        AndBibleSettingsRowLabel(
            title: title,
            summary: summary,
            detail: detail,
            icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey),
            isEnabled: isEnabled
        )
    }

    /**
     Builds an Android-shaped settings section header using the active app accent color.

     - Parameter title: User-visible section title.
     - Returns: Section header aligned with row text rather than the icon column.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func settingsSectionHeader(_ title: String) -> AndBibleSettingsSectionHeader {
        AndBibleSettingsSectionHeader(title: title)
    }

    private var settingsAccessibilityValue: String {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return ""
        }
        let primaryLinks = [
            "settingsSyncLink",
            "settingsReadingProgressLink",
            "settingsTextDisplayLink",
            "settingsColorsLink",
        ].joined(separator: ",")
        let searchToken = isSettingsSearchActive ? "active" : "inactive"
        return "primaryLinks=\(primaryLinks);adminFlows=readerActions;search=\(searchToken)"
    }

    /**
     Reloads installed modules and persisted application preferences into local view state.

     This is shared by initial presentation and reset so the settings UI rehydrates from the same
     registry-backed store path in both flows.
     *
     - Side Effects:
       - queries SWORD for installed modules
       - reads SwiftData/UserDefaults-backed preferences through `SettingsStore`
       - sanitizes stale dictionary, bookmark-action, and experimental-feature selections
       - applies the keep-screen-on idle-timer side effect for the loaded value
     - Failure: Module discovery failures leave dictionary arrays empty; settings fetch failures
       fall back through `SettingsStore` defaults.
     */
    private func loadSettingsState() {
        loadInstalledDictionaryModules()
        hasLoadedPreferences = false

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
        loadPersistedInterfaceLanguage(using: store)
        hasLoadedPreferences = true
    }

    /**
     Refreshes installed dictionary module lists used by module-backed preferences.

     - Side Effects: Reads installed SWORD module metadata and updates the dictionary state arrays.
     - Failure: If the SWORD manager cannot be created, dictionary arrays are cleared.
     */
    private func loadInstalledDictionaryModules() {
        guard let mgr = SwordManager() else {
            strongsGreekDictionaries = []
            strongsHebrewDictionaries = []
            robinsonMorphologyDictionaries = []
            wordLookupDictionaries = []
            return
        }

        let all = mgr.installedModules()
        strongsGreekDictionaries = all
            .filter {
                ($0.category == .dictionary || $0.category == .glossary) &&
                    StrongsDictionaryPolicy.isSupportedDictionaryModuleName($0.name) &&
                    $0.features.contains(.greekDef)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        strongsHebrewDictionaries = all
            .filter {
                ($0.category == .dictionary || $0.category == .glossary) &&
                    StrongsDictionaryPolicy.isSupportedDictionaryModuleName($0.name) &&
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

    /**
     Loads the Android-parity interface language preference and migrates legacy iOS overrides.

     - Parameter store: Settings store used to read and repair `locale_pref`.
     - Side Effects:
       - may clear an invalid `locale_pref`
       - may persist a migrated value derived from `AppleLanguages`
     - Failure: Unsupported locale values fall back to the default empty language selection.
     */
    private func loadPersistedInterfaceLanguage(using store: SettingsStore) {
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
    }

    /**
     Resets Android-parity application preferences and rehydrates visible settings state.

     Reset delegates the durable key contract to `SettingsStore.resetApplicationPreferences()` and
     only handles UI/platform side effects here, including clearing the iOS language override that
     backs `locale_pref`.
     *
     - Side Effects:
       - removes resettable SwiftData and UserDefaults preference values
       - clears the `AppleLanguages` override associated with interface-language selection
       - reapplies loaded keep-screen-on state
       - invokes `onSettingsChanged` so reader panes refresh global display/behavior settings
     - Failure: Store failures follow the soft-failure behavior documented by `SettingsStore`.
     */
    private func resetApplicationPreferences() {
        let store = SettingsStore(modelContext: modelContext)
        store.resetApplicationPreferences()
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        loadSettingsState()
        onSettingsChanged?()
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
