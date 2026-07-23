// AndroidReadingProgressSettingsView.swift -- App-owned ReadingProgressSettingsActivity

import BibleCore
import SwiftUI

/**
 Canonical projection of Android `reading_progress_settings.xml` row order and resources.

 Raw values are the exact Android preference keys, making the parity contract directly testable
 without rendering localized SwiftUI. Titles, summaries, icons, and automation identifiers remain
 centralized so adding or reordering a row cannot silently drift from Android XML.
 */
enum AndroidReadingProgressPreference: String, CaseIterable, Identifiable {
    case autoMarkMemorized = "auto_mark_memorized"
    case typeFullWords = "memorize_type_full_words"
    case wordVisibility = "memorize_word_visibility"
    case errorHeatmap = "memorize_error_heatmap"
    case scrambleHideUsed = "memorize_scramble_hide_used"
    case includeReference = "memorize_include_reference"

    var id: String { rawValue }

    /// Exact ported Android drawable asset for the row.
    var iconName: String {
        switch self {
        case .autoMarkMemorized: "ProgressAutoMark"
        case .typeFullWords: "ProgressTypeFullWords"
        case .wordVisibility: "ProgressWordVisibility"
        case .errorHeatmap: "ProgressErrorHeatmap"
        case .scrambleHideUsed: "ProgressHideUsedWords"
        case .includeReference: "ProgressIncludeReference"
        }
    }

    /// Exact Android summary resource key used by localization parity tests.
    var summaryResourceKey: String {
        switch self {
        case .autoMarkMemorized: "memorize_auto_mark_summary"
        case .typeFullWords: "memorize_type_full_words_summary"
        case .wordVisibility: "memorize_word_visibility_summary"
        case .errorHeatmap: "memorize_error_heatmap_summary"
        case .scrambleHideUsed: "memorize_scramble_hide_used_summary"
        case .includeReference: "memorize_include_reference_summary"
        }
    }

    /// Localized Android preference title.
    var localizedTitle: String {
        switch self {
        case .autoMarkMemorized:
            String(localized: "memorize_auto_mark", defaultValue: "Auto-mark as memorized")
        case .typeFullWords:
            String(localized: "memorize_type_full_words", defaultValue: "Type full words")
        case .wordVisibility:
            String(localized: "memorize_word_visibility", defaultValue: "Word visibility")
        case .errorHeatmap:
            String(localized: "memorize_error_heatmap", defaultValue: "Error heatmap")
        case .scrambleHideUsed:
            String(localized: "memorize_scramble_hide_used", defaultValue: "Hide used word buttons")
        case .includeReference:
            String(localized: "memorize_include_reference", defaultValue: "Include verse reference")
        }
    }

    /// Localized Android preference summary.
    var localizedSummary: String {
        switch self {
        case .autoMarkMemorized:
            String(localized: "memorize_auto_mark_summary", defaultValue: "Automatically mark verses as memorized when an exercise is completed")
        case .typeFullWords:
            String(localized: "memorize_type_full_words_summary", defaultValue: "Require typing the complete word instead of just the first letter")
        case .wordVisibility:
            String(localized: "memorize_word_visibility_summary", defaultValue: "How visible untyped words are: light hint, dim, or completely hidden")
        case .errorHeatmap:
            String(localized: "memorize_error_heatmap_summary", defaultValue: "Highlight words with more errors in progressively deeper red")
        case .scrambleHideUsed:
            String(localized: "memorize_scramble_hide_used_summary", defaultValue: "Hide word buttons completely after they are correctly placed in word scramble mode")
        case .includeReference:
            String(localized: "memorize_include_reference_summary", defaultValue: "Add the verse reference (e.g. John 3:16) as the last item to memorize")
        }
    }

    /// Stable UI-test identity for the app-owned preference row.
    var accessibilityIdentifier: String {
        switch self {
        case .autoMarkMemorized: "readingProgressAutoMarkPreference"
        case .typeFullWords: "readingProgressFullWordsPreference"
        case .wordVisibility: "readingProgressWordVisibilityPreference"
        case .errorHeatmap: "readingProgressErrorHeatmapPreference"
        case .scrambleHideUsed: "readingProgressHideUsedPreference"
        case .includeReference: "readingProgressIncludeReferencePreference"
        }
    }
}

/**
 Renders Android ReadingProgressSettingsActivity from the exact preference XML contract.

 The activity contains the same six rows, order, localized titles/summaries, and ported icons as
 Android `reading_progress_settings.xml`. It deliberately excludes the unrelated native-only
 `autoTrackReading` field and composes shared app bar, preference-switch, and single-choice dialog
 controls instead of `Form`, `Section`, `Toggle`, `Picker`, or native navigation chrome.

 Inputs: optional reader controller, optional reader/workspace palette, and optional explicit Back
 command for a reader-owned destination

 Output: one full-screen app-owned Progress & memorization settings activity

 Side effects: row changes save the complete progress settings snapshot through the controller

 Failure modes: save failure restores the previous local snapshot and presents a shared Android
 error dialog; a missing controller keeps changes local for deterministic preview/test behavior
 */
struct ReadingProgressSettingsView: View {
    /// Controller that owns settings persistence and bridge refresh behavior.
    let controller: BibleReaderController?

    /// Reader/workspace palette when launched from a captured pane.
    private let suppliedSurfacePalette: ReaderThemeSurfacePalette?

    /// Explicit Android Up command for reader-owned routing.
    private let suppliedOnBack: (() -> Void)?

    /// Local projection of the persisted settings snapshot.
    @State private var settings: ReadingProgressSettingsSnapshot

    /// App-owned ListPreference dialog visibility.
    @State private var showsWordVisibilityDialog = false

    /// Failed save feedback state.
    @State private var persistenceFailure = false

    /// Environment dismissal used by the Application Preferences navigation entry.
    @Environment(\.dismiss) private var dismiss

    /// Active appearance used for fallback surfaces and AppCompat accent.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates Android Progress & memorization settings.

     - Parameters:
       - controller: Optional owner of the persisted progress snapshot.
       - surfacePalette: Captured reader palette, or nil to derive the active application scheme.
       - onBack: Explicit reader route command, or nil to pop the enclosing navigation path.
     - Side effects: none during initialization.
     - Failure modes: malformed persisted state has already been normalized by the store snapshot.
     */
    init(
        controller: BibleReaderController?,
        surfacePalette: ReaderThemeSurfacePalette? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.controller = controller
        suppliedSurfacePalette = surfacePalette
        suppliedOnBack = onBack
        _settings = State(initialValue:
            controller?.readingProgressStore?.snapshot().settings
                ?? ReadingProgressSettingsSnapshot()
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(
                    localized: "reading_progress_settings",
                    defaultValue: "Progress & memorization"
                ),
                accessibilityIdentifier: "readingProgressSettingsAppBar",
                palette: surfacePalette,
                onBack: performBack
            ) {
                EmptyView()
            } content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(AndroidReadingProgressPreference.allCases) { preference in
                            preferenceRow(preference)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }

            AndroidActivityAccessibilityMarker(
                label: String(
                    localized: "reading_progress_settings",
                    defaultValue: "Progress & memorization"
                ),
                accessibilityIdentifier: "readingProgressSettingsScreen",
                surfaceColor: surfacePalette.backgroundColor
            )

            if showsWordVisibilityDialog {
                AndroidSingleChoiceDialog(
                    title: String(
                        localized: "memorize_word_visibility",
                        defaultValue: "Word visibility"
                    ),
                    selectedValue: settings.memorizeWordVisibility,
                    options: wordVisibilityOptions,
                    accessibilityIdentifier: "readingProgressWordVisibilityDialog",
                    onSelect: { value in
                        persist(value, at: \.memorizeWordVisibility)
                        showsWordVisibilityDialog = false
                    },
                    onCancel: { showsWordVisibilityDialog = false }
                )
            }

            if persistenceFailure {
                AndroidDecisionDialog(
                    title: String(
                        localized: "reading_progress_save_failed",
                        defaultValue: "Unable to save progress"
                    ),
                    message: String(
                        localized: "reading_progress_save_failed_message",
                        defaultValue: "Your existing progress was left unchanged. Try again."
                    ),
                    actions: [
                        .init(
                            id: "okay",
                            title: String(localized: "okay", defaultValue: "OK"),
                            style: .normal
                        ) { persistenceFailure = false },
                    ],
                    accessibilityIdentifier: "readingProgressSettingsSaveFailureDialog"
                )
            }
        }
    }

    /// Owner palette or active global day/night fallback when no reader pane launched the route.
    private var surfacePalette: ReaderThemeSurfacePalette {
        suppliedSurfacePalette ?? ReaderThemeSurfacePalette(
            settings: .appDefaults,
            nightMode: colorScheme == .dark
        )
    }

    /// Android word-visibility values in exact array order.
    private var wordVisibilityOptions: [AndroidSingleChoiceOption<String>] {
        [
            .init(
                id: "light",
                value: "light",
                title: String(localized: "memorize_word_visibility_light", defaultValue: "Light")
            ),
            .init(
                id: "dim",
                value: "dim",
                title: String(localized: "memorize_word_visibility_dim", defaultValue: "Dim")
            ),
            .init(
                id: "hidden",
                value: "hidden",
                title: String(localized: "memorize_word_visibility_hidden", defaultValue: "Hidden")
            ),
        ]
    }

    /** Builds one canonical XML-backed preference plus Android's subtle row divider. */
    @ViewBuilder
    private func preferenceRow(_ preference: AndroidReadingProgressPreference) -> some View {
        VStack(spacing: 0) {
            if preference == .wordVisibility {
                AndroidActionPreferenceRow(
                    icon: .asset(preference.iconName),
                    title: preference.localizedTitle,
                    summary: preference.localizedSummary,
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accessibilityIdentifier: preference.accessibilityIdentifier
                ) {
                    showsWordVisibilityDialog = true
                }
            } else if let booleanBinding = booleanBinding(for: preference) {
                AndroidSwitchPreferenceRow(
                    icon: .asset(preference.iconName),
                    title: preference.localizedTitle,
                    summary: preference.localizedSummary,
                    isOn: booleanBinding,
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                    accessibilityIdentifier: preference.accessibilityIdentifier
                )
            }
            Divider().overlay(surfacePalette.inactiveBorderColor)
        }
    }

    /** Resolves the exact Boolean snapshot field represented by one SwitchPreference row. */
    private func booleanBinding(
        for preference: AndroidReadingProgressPreference
    ) -> Binding<Bool>? {
        switch preference {
        case .autoMarkMemorized:
            settingBinding(\.autoMarkMemorized)
        case .typeFullWords:
            settingBinding(\.memorizeTypeFullWords)
        case .errorHeatmap:
            settingBinding(\.memorizeErrorHeatmap)
        case .scrambleHideUsed:
            settingBinding(\.memorizeScrambleHideUsed)
        case .includeReference:
            settingBinding(\.memorizeIncludeReference)
        case .wordVisibility:
            nil
        }
    }

    /** Invokes the explicit reader return route or pops the enclosing application navigation path. */
    private func performBack() {
        if let suppliedOnBack {
            suppliedOnBack()
        } else {
            dismiss()
        }
    }

    /**
     Creates a Boolean binding that saves through the complete normalized settings snapshot.

     - Parameter keyPath: Writable Boolean preference represented by an Android switch row.
     - Returns: Binding whose setter calls `persist(_:at:)` exactly once.
     - Side effects: successful edits persist and refresh local state.
     - Failure modes: failed saves restore the prior snapshot and raise shared error feedback.
     */
    private func settingBinding(
        _ keyPath: WritableKeyPath<ReadingProgressSettingsSnapshot, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { persist($0, at: keyPath) }
        )
    }

    /**
     Persists one typed preference edit while retaining every unrelated progress field.

     - Parameters:
       - value: New preference value.
       - keyPath: Exact snapshot field to replace.
     - Side effects: mutates local state and may save through `BibleReaderController`.
     - Failure modes: a controller save returning nil restores the previous value and shows error
       feedback; missing controllers intentionally retain local state without persistence.
     */
    private func persist<Value>(
        _ value: Value,
        at keyPath: WritableKeyPath<ReadingProgressSettingsSnapshot, Value>
    ) {
        let previous = settings
        settings[keyPath: keyPath] = value
        guard let controller else { return }
        guard let savedSettings = controller.saveReadingProgressSettings(settings) else {
            settings = previous
            persistenceFailure = true
            return
        }
        settings = savedSettings
    }
}
