// SpeakControlView.swift -- App-owned Android Speak activities

import BibleCore
import SwiftUI
import SwordKit
#if canImport(UIKit)
import UIKit
#endif

/** Android's 1-through-120-minute sleep-timer selection contract. */
struct SpeakTimerSelection {
    static let validMinutes = 1...120

    /** Clamps a restored picker default into Android's addressable minute range. */
    static func normalized(_ minutes: Int) -> Int {
        min(max(minutes, validMinutes.lowerBound), validMinutes.upperBound)
    }
}

/** Two-stage exact-position state used by Android's beginning/end passage chooser. */
struct SpeakVerseRangeDraft {
    enum Selection: Equatable {
        case awaitingEnd
        case completed(start: SpeakStreamPosition, end: SpeakStreamPosition)
        case invalid
    }

    let positions: [SpeakStreamPosition]
    private(set) var start: SpeakStreamPosition? = nil

    /// Positions valid for the current beginning or ending selection stage.
    var availablePositions: [SpeakStreamPosition] {
        guard let start,
              let startIndex = positions.firstIndex(of: start) else {
            return Array(positions.dropLast())
        }
        return Array(positions.dropFirst(startIndex + 1))
    }

    /** Selects a beginning first, then requires a strictly later ending position. */
    mutating func select(_ position: SpeakStreamPosition) -> Selection {
        guard positions.contains(position) else { return .invalid }
        guard let start else {
            guard position != positions.last else { return .invalid }
            self.start = position
            return .awaitingEnd
        }
        guard let startIndex = positions.firstIndex(of: start),
              let endIndex = positions.firstIndex(of: position),
              endIndex > startIndex else {
            return .invalid
        }
        return .completed(start: start, end: position)
    }
}

/** Pure visibility contract for Android's repeated-verse editor control. */
struct SpeakVerseRangeControlAvailability {
    /**
     Returns whether a provider can expose a useful contiguous range editor.

     - Parameters:
       - supportsEditing: Provider capability supplied by `SpeakService`.
       - positionCount: Number of exact positions available for a start/end selection.
     - Returns: `true` only for editable providers with at least two positions.
     - Side effects: None.
     - Failure modes: Unsupported or undersized streams fail closed by returning `false`.
     */
    static func isVisible(supportsEditing: Bool, positionCount: Int) -> Bool {
        supportsEditing && positionCount > 1
    }
}

/**
 Projects a full Bible speech provider into the existing Android passage-chooser component.

 The reader normally supplies its active module's exact `BookInfo` catalog. Tests and legacy
 callers can omit that catalog; in that case this helper derives stable book metadata from the
 provider's complete OSIS position set and the pinned JSword KJVA catalog.
 */
struct SpeakPassageChooserCatalog {
    /** Derives one ordered book row for every OSIS id represented by provider positions. */
    static func books(from positions: [SpeakStreamPosition]) -> [BookInfo] {
        var orderedIDs: [String] = []
        var maxChapterByID: [String: Int] = [:]
        for position in positions {
            guard let osisId = osisBookID(for: position), let chapter = position.chapter else { continue }
            if maxChapterByID[osisId] == nil { orderedIDs.append(osisId) }
            maxChapterByID[osisId] = max(maxChapterByID[osisId] ?? 0, chapter)
        }

        let kjvaByID = Dictionary(uniqueKeysWithValues: JSwordKJVAVersification.books.map { ($0.osisId, $0) })
        return orderedIDs.compactMap { osisId in
            let summary = kjvaByID[osisId]
            guard let chapterCount = maxChapterByID[osisId], chapterCount > 0 else { return nil }
            return BookInfo(
                name: summary?.longName ?? osisId,
                osisId: osisId,
                abbreviation: summary?.shortName ?? osisId,
                chapterCount: chapterCount,
                testament: summary?.isNewTestament == true ? 2 : 1
            )
        }
    }

    /** Returns the provider's exact verse count for a book/chapter chooser cell. */
    static func verseCount(
        for book: BookInfo,
        chapter: Int,
        positions: [SpeakStreamPosition]
    ) -> Int? {
        let verses = positions.compactMap { position -> Int? in
            guard osisBookID(for: position) == book.osisId,
                  position.chapter == chapter else { return nil }
            return position.verse
        }
        return verses.max()
    }

    /** Resolves one shared passage-chooser result back to the provider's exact source position. */
    static func position(
        book: BookInfo,
        chapter: Int,
        verse: Int,
        positions: [SpeakStreamPosition]
    ) -> SpeakStreamPosition? {
        positions.first {
            osisBookID(for: $0) == book.osisId
                && $0.chapter == chapter
                && $0.verse == verse
        }
    }

    /** Extracts a three-part OSIS position's book id without interpreting display text. */
    private static func osisBookID(for position: SpeakStreamPosition) -> String? {
        position.osisRef?.split(separator: ".", maxSplits: 1).first.map(String.init)
    }
}

/** Reader-owned child activities reachable from Android's Speak configuration screen. */
private enum SpeakControlDestination {
    case advancedSettings
    case verseRange
}

/**
 App-owned implementation of Android's `BibleSpeakActivity`.

 The screen uses the shared activity bar, anchored popup, checkbox, seek bar, number picker,
 passage chooser, dialog, and transport components. Advanced settings are a separate app-owned
 child activity just as on Android; the system TTS command remains an explicit platform boundary.
 */
public struct SpeakControlView: View {
    @ObservedObject var speakService: SpeakService
    private let surfacePalette: ReaderThemeSurfacePalette
    private let passageBooks: [BookInfo]
    private let verseCountProvider: (BookInfo, Int) -> Int?
    private let onBack: () -> Void

    @State private var speed: Double
    @State private var timerMinutes: Int
    @State private var destination: SpeakControlDestination?
    @State private var showsOverflowMenu = false
    @State private var showsHelp = false
    @State private var showsSleepTimerPicker = false
    @State private var showsBookmarkPicker = false
    @State private var toastMessage: String?

    @Environment(\.openURL) private var openURL

    /** Creates the compatibility entry point used outside reader-owned presentation. */
    public init(speakService: SpeakService) {
        self.init(
            speakService: speakService,
            surfacePalette: .standard,
            passageBooks: [],
            verseCountProvider: nil,
            onBack: {}
        )
    }

    /** Creates one reader-owned Speak activity with the active window palette and module canon. */
    init(
        speakService: SpeakService,
        surfacePalette: ReaderThemeSurfacePalette,
        passageBooks: [BookInfo],
        verseCountProvider: ((BookInfo, Int) -> Int?)?,
        onBack: @escaping () -> Void
    ) {
        self.speakService = speakService
        self.surfacePalette = surfacePalette
        self.passageBooks = passageBooks
        self.verseCountProvider = verseCountProvider ?? { book, chapter in
            SpeakPassageChooserCatalog.verseCount(
                for: book,
                chapter: chapter,
                positions: speakService.availableBiblePositions
            )
        }
        self.onBack = onBack
        _speed = State(initialValue: speakService.userSpeed)
        _timerMinutes = State(
            initialValue: SpeakTimerSelection.normalized(speakService.settings.lastSleepTimer)
        )
    }

    public var body: some View {
        ZStack {
            mainActivity
            destinationLayer
        }
        .onChange(of: speakService.userSpeed) { _, newValue in
            if abs(speed - newValue) >= 0.001 { speed = newValue }
        }
        .onChange(of: speakService.settings.lastSleepTimer) { _, newValue in
            timerMinutes = SpeakTimerSelection.normalized(newValue)
        }
        .onChange(of: speakService.supportsVerseRangeEditing) { _, isSupported in
            if !isSupported, destination == .verseRange { destination = nil }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// Complete Android `BibleSpeakActivity` content and shared overlays.
    private var mainActivity: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivitySurface(palette: surfacePalette) {
                appBar
            } content: {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            playbackSection
                            speedSection
                            repeatPassageSection
                            sleepTimerSection
                        }
                        .padding(5)
                    }
                    AndroidSpeakTransportView(
                        speakService: speakService,
                        surfacePalette: surfacePalette,
                        fallbackStatus: String(localized: "speak_stopped", defaultValue: "Stopped"),
                        onShowBookmarks: { showsBookmarkPicker = true },
                        onShowConfiguration: nil
                    )
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "speak", defaultValue: "Speak"),
                accessibilityIdentifier: "speakControlActivity",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: "speakOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 300,
            estimatedMenuHeight: 96,
            accessibilityIdentifier: "speakOverflowMenu"
        ) {
            overflowMenu
        }
        .overlay { presentationLayer }
        .androidToastFeedback(toastMessage, bottomPadding: 100)
    }

    /// Android action bar: Up, Help, and overflow.
    private var appBar: some View {
        AndroidActivityTopAppBar(
            title: String(localized: "speak", defaultValue: "Speak"),
            accessibilityIdentifier: "speakControlAppBar",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            onBack: onBack
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("DrawerHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "speakHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsHelp = true }
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "speakOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsOverflowMenu.toggle() }
            )
            .androidPopupMenuAnchor(id: "speakOverflowAnchor")
        }
    }

    /// Android playback settings heading, subtitle, and three equal-width checkboxes.
    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(String(localized: "playback_settings_title", defaultValue: "Playback Settings"))
            subsectionTitle(String(
                localized: "speak_and_play_earcons_title",
                defaultValue: "Speak text and play sounds"
            ))
            HStack(alignment: .top, spacing: 4) {
                playbackCheckbox(
                    String(localized: "conf_change_chapter", defaultValue: "Chapter changes"),
                    keyPath: \.speakChapterChanges,
                    identifier: "speakChapterChanges"
                )
                playbackCheckbox(
                    String(localized: "conf_change_title", defaultValue: "Titles"),
                    keyPath: \.speakTitles,
                    identifier: "speakTitles"
                )
                playbackCheckbox(
                    String(localized: "conf_speak_footnotes", defaultValue: "Footnotes"),
                    keyPath: \.speakFootnotes,
                    identifier: "speakFootnotes"
                )
            }
            .padding(.horizontal, 8)
        }
    }

    /// Android speech-speed status and 0-through-300 percent seek bar.
    private var speedSection: some View {
        VStack(spacing: 0) {
            Divider().overlay(surfacePalette.inactiveBorderColor)
            HStack {
                subsectionTitle(String(localized: "speak_speed_title", defaultValue: "Speech speed"))
                Spacer()
                Text("\(Int((speed * 100).rounded())) %")
                    .font(.system(size: 16))
                    .monospacedDigit()
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .padding(.trailing, 10)
            }
            AndroidSeekBar(
                value: Binding(
                    get: { speed * 100 },
                    set: { value in
                        speed = value / 100
                        speakService.userSpeed = speed
                    }
                ),
                range: 0...300,
                step: 1,
                palette: surfacePalette,
                accessibilityIdentifier: "speakSpeed",
                accessibilityLabel: String(localized: "speak_speed_title", defaultValue: "Speech speed")
            )
            .padding(.horizontal, 8)
        }
    }

    /// Android repeated-passage section backed by the shared grid passage chooser.
    @ViewBuilder
    private var repeatPassageSection: some View {
        if SpeakVerseRangeControlAvailability.isVisible(
            supportsEditing: speakService.supportsVerseRangeEditing,
            positionCount: speakService.availableBiblePositions.count
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Divider().overlay(surfacePalette.inactiveBorderColor)
                subsectionTitle(String(localized: "repeat_passage", defaultValue: "Repeat passage"))
                AndroidCheckboxRow(
                    title: repeatPassageTitle,
                    isOn: Binding(
                        get: { speakService.settings.playbackSettings.verseRange != nil },
                        set: { enabled in
                            if enabled {
                                destination = .verseRange
                            } else {
                                _ = speakService.setVerseRange(start: nil, end: nil)
                            }
                        }
                    ),
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    accessibilityIdentifier: "speakRepeatPassage"
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 15)
            }
        }
    }

    /// Android sleep-timer heading and checkbox-driven number-picker action.
    private var sleepTimerSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().overlay(surfacePalette.inactiveBorderColor)
            sectionTitle(String(localized: "speak_sleep_timer_title", defaultValue: "Sleep Timer"))
            AndroidCheckboxRow(
                title: sleepTimerLabel,
                isOn: Binding(
                    get: { speakService.settings.sleepTimer > 0 },
                    set: { enabled in
                        if enabled {
                            showsSleepTimerPicker = true
                        } else {
                            speakService.setSleepTimer(minutes: nil)
                        }
                    }
                ),
                foregroundColor: surfacePalette.foregroundColor,
                accentColor: surfacePalette.controlAccentColor,
                accessibilityIdentifier: "speakSleepTimer"
            )
            .padding(.horizontal, 8)
        }
    }

    /// Android overflow commands in source menu order after the always-visible Help action.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "speakOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(localized: "speak_advanced_settings", defaultValue: "Advanced settings"),
                    icon: .asset("SpeakSettings"),
                    accessibilityIdentifier: "speakAdvancedSettingsAction"
                ) {
                    showsOverflowMenu = false
                    destination = .advancedSettings
                }
                AndroidPopupMenuRow(
                    title: String(localized: "system_speak_settings", defaultValue: "Open system TTS settings"),
                    accessibilityIdentifier: "speakSystemSettingsAction"
                ) {
                    showsOverflowMenu = false
                    openSystemSpeechSettings()
                }
            }
        }
    }

    /// App-owned Android dialogs presented above the main activity.
    @ViewBuilder
    private var presentationLayer: some View {
        if showsHelp {
            AndroidSpeakHelpDialog(mode: .playback) { showsHelp = false }
        } else if showsSleepTimerPicker {
            AndroidNumberPickerDialog(
                title: String(localized: "sleep_timer_title", defaultValue: "Sleep time in minutes"),
                range: SpeakTimerSelection.validMinutes,
                initialValue: timerMinutes,
                accessibilityIdentifier: "speakSleepTimerDialog",
                onConfirm: { minutes in
                    timerMinutes = minutes
                    speakService.setSleepTimer(minutes: minutes)
                    showsSleepTimerPicker = false
                },
                onCancel: { showsSleepTimerPicker = false }
            )
        } else if showsBookmarkPicker {
            speakBookmarkDialog(onDismiss: { showsBookmarkPicker = false })
        }
    }

    /// Full app-owned child activity selected from main Speak controls.
    @ViewBuilder
    private var destinationLayer: some View {
        switch destination {
        case .advancedSettings:
            AndroidAdvancedSpeakSettingsView(
                speakService: speakService,
                surfacePalette: surfacePalette,
                onBack: { destination = nil }
            )
        case .verseRange:
            SpeakVerseRangeEditor(
                positions: speakService.availableBiblePositions,
                books: resolvedPassageBooks,
                verseCountProvider: verseCountProvider,
                onApply: speakService.setVerseRange,
                onCancel: { destination = nil },
                onInvalid: {
                    destination = nil
                    showToast(String(
                        localized: "speak_ending_verse_must_be_later",
                        defaultValue: "The ending verse must be later than the beginning verse"
                    ))
                }
            )
        case nil:
            EmptyView()
        }
    }

    /// Reader-supplied module books or a deterministic provider-derived compatibility catalog.
    private var resolvedPassageBooks: [BookInfo] {
        passageBooks.isEmpty
            ? SpeakPassageChooserCatalog.books(from: speakService.availableBiblePositions)
            : passageBooks
    }

    /// Android range checkbox title: current range name when set, otherwise the setup command.
    private var repeatPassageTitle: String {
        guard let range = speakService.settings.playbackSettings.verseRange else {
            return String(
                localized: "speak_verse_range_to_repeat",
                defaultValue: "Set passage range to repeat"
            )
        }
        return range.osisRef
    }

    /// Android sleep-timer checkbox copy, including the persisted minute selection while active.
    private var sleepTimerLabel: String {
        guard speakService.settings.sleepTimer > 0 else {
            return String(localized: "conf_speak_sleep_timer", defaultValue: "Set sleep timer")
        }
        let format = String(
            localized: "sleep_timer_set",
            defaultValue: "Set sleep timer. Timer set: %lld minutes"
        )
        return String(format: format, Int64(speakService.settings.sleepTimer))
    }

    /// App-owned bookmark list dialog shared by main and advanced Speak activities.
    private func speakBookmarkDialog(onDismiss: @escaping () -> Void) -> some View {
        AndroidSingleChoiceDialog(
            title: String(localized: "speak_bookmarks_menu_title", defaultValue: "Speak from bookmark"),
            selectedValue: -1,
            options: speakService.resumeBookmarks.enumerated().map { index, bookmark in
                AndroidSingleChoiceOption(id: "\(index)", value: index, title: resumeTitle(for: bookmark))
            },
            accessibilityIdentifier: "speakBookmarkDialog",
            onSelect: { index in
                guard speakService.resumeBookmarks.indices.contains(index) else {
                    onDismiss()
                    return
                }
                speakService.resume(from: speakService.resumeBookmarks[index])
                onDismiss()
            },
            onCancel: onDismiss
        )
    }

    /** Creates one equal-width Android playback checkbox. */
    private func playbackCheckbox(
        _ title: String,
        keyPath: WritableKeyPath<PlaybackSettings, Bool>,
        identifier: String
    ) -> some View {
        AndroidCheckboxRow(
            title: title,
            isOn: playbackBinding(keyPath),
            foregroundColor: surfacePalette.foregroundColor,
            accentColor: surfacePalette.controlAccentColor,
            accessibilityIdentifier: identifier
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /** Creates Android's large activity-section title treatment. */
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .padding(10)
            .foregroundStyle(surfacePalette.foregroundColor)
    }

    /** Creates Android's bold subsection label treatment. */
    private func subsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .padding(8)
            .foregroundStyle(surfacePalette.foregroundColor)
    }

    /** Builds a binding that applies one Android playback boolean through `SpeakService`. */
    private func playbackBinding(_ keyPath: WritableKeyPath<PlaybackSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { speakService.settings.playbackSettings[keyPath: keyPath] },
            set: { value in
                var playback = speakService.settings.playbackSettings
                playback[keyPath: keyPath] = value
                speakService.updatePlaybackSettings(playback)
            }
        )
    }

    /** Formats one bookmark row without interpreting generic keys as Bible references. */
    private func resumeTitle(for bookmark: SpeakResumeBookmark) -> String {
        let position = bookmark.position
        let source = position.bookName.isEmpty ? position.bookInitials : position.bookName
        if source.isEmpty { return position.keyName.isEmpty ? position.key : position.keyName }
        let key = position.keyName.isEmpty ? position.key : position.keyName
        return key.isEmpty ? source : "\(source) \(key)"
    }

    /** Opens the public iOS application-settings boundary for system-managed speech resources. */
    private func openSystemSpeechSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }

    /** Shows one Android-short toast and removes it after the canonical duration. */
    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            if toastMessage == message { toastMessage = nil }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}

/** App-owned Android `SpeakSettingsActivity`, kept separate from the playback screen. */
private struct AndroidAdvancedSpeakSettingsView: View {
    @ObservedObject var speakService: SpeakService
    let surfacePalette: ReaderThemeSurfacePalette
    let onBack: () -> Void

    @State private var showsHelp = false
    @State private var showsBookmarkPicker = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "speak_advanced_settings", defaultValue: "Advanced settings"),
                accessibilityIdentifier: "advancedSpeakAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DrawerHelp"),
                    accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                    accessibilityIdentifier: "advancedSpeakHelpButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showsHelp = true }
                )
            } content: {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            AndroidPreferenceSection(
                                title: String(localized: "speak_settings_title", defaultValue: "Speak settings"),
                                palette: surfacePalette
                            ) {
                                advancedCheckbox(
                                    String(localized: "conf_speak_synchronize", defaultValue: "Synchronize text while speaking"),
                                    keyPath: \.synchronize,
                                    identifier: "advancedSpeakSynchronize"
                                )
                                AndroidPreferenceDivider(palette: surfacePalette)
                                advancedCheckbox(
                                    String(localized: "conf_replace_divinename", defaultValue: "Replace divine name"),
                                    keyPath: \.replaceDivineName,
                                    identifier: "advancedSpeakReplaceDivineName"
                                )
                            }

                            AndroidPreferenceSection(
                                title: String(
                                    localized: "speak_bookmarking_settings_title",
                                    defaultValue: "Speak Bookmarking Settings"
                                ),
                                palette: surfacePalette
                            ) {
                                advancedCheckbox(
                                    String(localized: "conf_speak_auto_bookmark", defaultValue: "Automatically add Speak bookmark"),
                                    keyPath: \.autoBookmark,
                                    identifier: "advancedSpeakAutoBookmark"
                                )
                                AndroidPreferenceDivider(palette: surfacePalette)
                                advancedCheckbox(
                                    String(
                                        localized: "conf_save_playback_settings_to_bookmarks",
                                        defaultValue: "Save playback settings to bookmarks"
                                    ),
                                    keyPath: \.restoreSettingsFromBookmarks,
                                    identifier: "advancedSpeakRestoreBookmarkSettings"
                                )
                            }
                        }
                    }

                    AndroidSpeakTransportView(
                        speakService: speakService,
                        surfacePalette: surfacePalette,
                        fallbackStatus: String(localized: "speak_stopped", defaultValue: "Stopped"),
                        onShowBookmarks: { showsBookmarkPicker = true },
                        onShowConfiguration: nil
                    )
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "speak_advanced_settings", defaultValue: "Advanced settings"),
                accessibilityIdentifier: "advancedSpeakActivity",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .overlay { presentationLayer }
    }

    /// App-owned dialogs belonging to the advanced activity.
    @ViewBuilder
    private var presentationLayer: some View {
        if showsHelp {
            AndroidSpeakHelpDialog(mode: .advanced) { showsHelp = false }
        } else if showsBookmarkPicker {
            AndroidSingleChoiceDialog(
                title: String(localized: "speak_bookmarks_menu_title", defaultValue: "Speak from bookmark"),
                selectedValue: -1,
                options: speakService.resumeBookmarks.enumerated().map { index, bookmark in
                    AndroidSingleChoiceOption(
                        id: "\(index)",
                        value: index,
                        title: bookmark.position.keyName.isEmpty
                            ? bookmark.position.key
                            : bookmark.position.keyName
                    )
                },
                accessibilityIdentifier: "advancedSpeakBookmarkDialog",
                onSelect: { index in
                    if speakService.resumeBookmarks.indices.contains(index) {
                        speakService.resume(from: speakService.resumeBookmarks[index])
                    }
                    showsBookmarkPicker = false
                },
                onCancel: { showsBookmarkPicker = false }
            )
        }
    }

    /** Builds one shared Android checkbox row backed by global advanced settings. */
    private func advancedCheckbox(
        _ title: String,
        keyPath: WritableKeyPath<AdvancedSpeakSettings, Bool>,
        identifier: String
    ) -> some View {
        AndroidCheckboxRow(
            title: title,
            isOn: Binding(
                get: { speakService.advancedSettings[keyPath: keyPath] },
                set: { value in
                    var settings = speakService.advancedSettings
                    settings[keyPath: keyPath] = value
                    speakService.updateAdvancedSettings(settings)
                }
            ),
            foregroundColor: surfacePalette.foregroundColor,
            accentColor: surfacePalette.controlAccentColor,
            accessibilityIdentifier: identifier
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }
}

/** Full shared-grid replacement for Android's two `GridChoosePassageBook` requests. */
private struct SpeakVerseRangeEditor: View {
    @State private var draft: SpeakVerseRangeDraft

    let books: [BookInfo]
    let verseCountProvider: (BookInfo, Int) -> Int?
    let onApply: (SpeakStreamPosition?, SpeakStreamPosition?) -> Bool
    let onCancel: () -> Void
    let onInvalid: () -> Void

    /** Creates a fresh beginning-stage chooser over the provider's full exact Bible positions. */
    init(
        positions: [SpeakStreamPosition],
        books: [BookInfo],
        verseCountProvider: @escaping (BookInfo, Int) -> Int?,
        onApply: @escaping (SpeakStreamPosition?, SpeakStreamPosition?) -> Bool,
        onCancel: @escaping () -> Void,
        onInvalid: @escaping () -> Void
    ) {
        _draft = State(initialValue: SpeakVerseRangeDraft(positions: positions))
        self.books = books
        self.verseCountProvider = verseCountProvider
        self.onApply = onApply
        self.onCancel = onCancel
        self.onInvalid = onInvalid
    }

    var body: some View {
        BookChooserView(
            books: books,
            selectionTitle: String(
                localized: draft.start == nil
                    ? "speak_beginning_of_passage"
                    : "speak_ending_of_passage",
                defaultValue: draft.start == nil
                    ? "Beginning of passage"
                    : "Ending of passage"
            ),
            navigateToVerse: true,
            verseCountProvider: verseCountProvider,
            onCancel: onCancel,
            onSelect: select(bookName:chapter:verse:)
        )
        .id(draft.start?.id ?? "speakRangeBeginning")
        .accessibilityIdentifier("speakVerseRangeChooser")
    }

    /** Advances Android's beginning/end flow from a shared passage-chooser result. */
    private func select(bookName: String, chapter: Int, verse: Int?) {
        guard let verse,
              let book = books.first(where: { $0.name == bookName }),
              let position = SpeakPassageChooserCatalog.position(
                  book: book,
                  chapter: chapter,
                  verse: verse,
                  positions: draft.positions
              ) else {
            onInvalid()
            return
        }

        switch draft.select(position) {
        case .awaitingEnd:
            return
        case .completed(let start, let end):
            if onApply(start, end) {
                onCancel()
            } else {
                onInvalid()
            }
        case .invalid:
            onInvalid()
        }
    }
}
