// SpeakControlView.swift — Text-to-Speech playback controls

import SwiftUI
import BibleCore
import AVFoundation

/** Android's valid sleep-timer picker domain and persisted-default normalization. */
struct SpeakTimerSelection {
    /// Inclusive values exposed by Android's `NumberPicker`.
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

    /** Positions valid for the current beginning or ending selection stage. */
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
 Playback control surface for text-to-speech reading.

 The view reflects the current `SpeakService` state and exposes Android-equivalent provider
 transport, Speak-bookmark resume, playback settings, advanced settings, speed, and sleep timer
 controls.

 Data dependencies:
 - `speakService` is the observable playback service that owns speaking state and control methods

 Side effects:
 - transport buttons call playback control methods on `SpeakService`
 - playback and advanced controls persist complete structured speech settings
 - speed slider and preset buttons persist a new `userSpeed` value on the service
 - sleep timer buttons set or clear the service's countdown timer
 - resume selections ask the reader to reconstruct the bookmarked provider
 */
public struct SpeakControlView: View {
    /// Observable speaking service backing all control state and actions.
    @ObservedObject var speakService: SpeakService

    /// Local speed slider value kept in sync with `SpeakService.userSpeed`.
    @State private var speed: Double

    /// Android timer picker value seeded from `lastSleepTimer` and constrained to 1 through 120.
    @State private var timerMinutes: Int

    /// Whether Android's two-stage repeated-passage chooser is visible.
    @State private var showVerseRangeEditor = false

    /// Preset speaking-speed buttons shown under the slider.
    private let speedPresets: [(label: String, value: Double)] = [
        ("0.75x", 0.75),
        ("1.0x", 1.0),
        ("1.25x", 1.25),
        ("1.5x", 1.5),
    ]

    /**
     Creates the speak-control surface for one `SpeakService`.

     - Parameter speakService: Observable service that owns playback state and control methods.
     */
    public init(speakService: SpeakService) {
        self.speakService = speakService
        self._speed = State(initialValue: speakService.userSpeed)
        self._timerMinutes = State(
            initialValue: SpeakTimerSelection.normalized(speakService.settings.lastSleepTimer)
        )
    }

    /**
     Builds the speech status, settings, timer, resume picker, and provider transport controls.
     */
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    speechStatus
                    resumePicker
                    playbackControls
                    verseRangeControls
                    speedControls
                    advancedControls
                    sleepTimerControls
                }
                .padding()
            }

            Divider()
            transportControls
                .padding(.horizontal)
                .padding(.vertical, 12)
        }
        .onChange(of: speakService.userSpeed) { _, newValue in
            if abs(speed - newValue) >= 0.001 {
                speed = newValue
            }
        }
        .onChange(of: speakService.settings.lastSleepTimer) { _, newValue in
            timerMinutes = SpeakTimerSelection.normalized(newValue)
        }
        .onChange(of: speakService.supportsVerseRangeEditing) { _, isSupported in
            if !isSupported {
                showVerseRangeEditor = false
            }
        }
        .navigationDestination(isPresented: $showVerseRangeEditor) {
            SpeakVerseRangeEditor(
                positions: speakService.availableBiblePositions,
                onApply: speakService.setVerseRange
            )
        }
    }

    /// Current title, subtitle, and playback state.
    private var speechStatus: some View {
        VStack(spacing: 4) {
            Text(speakService.currentTitle ?? stateLabel)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let subtitle = speakService.currentSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Android-equivalent Speak-label bookmark picker.
    @ViewBuilder
    private var resumePicker: some View {
        if !speakService.resumeBookmarks.isEmpty {
            Menu {
                ForEach(speakService.resumeBookmarks) { bookmark in
                    Button {
                        speakService.resume(from: bookmark)
                    } label: {
                        Label(resumeTitle(for: bookmark), systemImage: "play.fill")
                    }
                }
            } label: {
                Label(String(localized: "speak_bookmarks_menu_title"), systemImage: "bookmark.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Android playback toggles that directly alter command synthesis.
    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "playback_settings_title"))
                .font(.subheadline.weight(.semibold))
            Toggle(String(localized: "conf_change_chapter"), isOn: playbackBinding(\.speakChapterChanges))
            Toggle(String(localized: "conf_change_title"), isOn: playbackBinding(\.speakTitles))
            Toggle(String(localized: "conf_speak_footnotes"), isOn: playbackBinding(\.speakFootnotes))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Android's checkbox-driven, two-stage repeated Bible passage setting.
    @ViewBuilder
    private var verseRangeControls: some View {
        if SpeakVerseRangeControlAvailability.isVisible(
            supportsEditing: speakService.supportsVerseRangeEditing,
            positionCount: speakService.availableBiblePositions.count
        ) {
            Toggle(
                String(localized: "speak_verse_range_to_repeat"),
                isOn: Binding(
                    get: { speakService.settings.playbackSettings.verseRange != nil },
                    set: { enabled in
                        if enabled {
                            showVerseRangeEditor = true
                        } else {
                            _ = speakService.setVerseRange(start: nil, end: nil)
                        }
                    }
                )
            )
        }
    }

    /// Android speech-rate slider and common rate presets.
    private var speedControls: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(localized: "speak_speed"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.1fx", speed))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: $speed, in: 0...3.0, step: 0.05)
                .onChange(of: speed) { _, newValue in
                    speakService.userSpeed = newValue
                }

            HStack(spacing: 8) {
                ForEach(speedPresets, id: \.value) { preset in
                    Button(preset.label) {
                        speed = preset.value
                        speakService.userSpeed = preset.value
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(abs(speed - preset.value) < 0.025 ? .accentColor : .secondary)
                }
            }
        }
    }

    /// Android global advanced speech preferences.
    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "speak_settings_title"))
                .font(.subheadline.weight(.semibold))
            Toggle(String(localized: "conf_speak_synchronize"), isOn: advancedBinding(\.synchronize))
            Toggle(String(localized: "conf_replace_divinename"), isOn: advancedBinding(\.replaceDivineName))
            Toggle(String(localized: "conf_speak_auto_bookmark"), isOn: advancedBinding(\.autoBookmark))
            Toggle(
                String(localized: "conf_save_playback_settings_to_bookmarks"),
                isOn: advancedBinding(\.restoreSettingsFromBookmarks)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Android 1-through-120 minute picker, enable toggle, and current countdown.
    private var sleepTimerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    String(localized: "conf_speak_sleep_timer"),
                    isOn: Binding(
                        get: { speakService.settings.sleepTimer > 0 },
                        set: { enabled in
                            speakService.setSleepTimer(minutes: enabled ? timerMinutes : nil)
                        }
                    )
                )
                Spacer()
                if let remaining = speakService.sleepTimerRemaining {
                    Text("\(Int(remaining / 60)):\(String(format: "%02d", Int(remaining) % 60))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }

            Stepper(
                value: $timerMinutes,
                in: SpeakTimerSelection.validMinutes,
                step: 1
            ) {
                HStack {
                    Text(String(localized: "sleep_timer_title"))
                    Spacer()
                    Text("\(timerMinutes)")
                        .monospacedDigit()
                }
            }
            .onChange(of: timerMinutes) { _, minutes in
                if speakService.settings.sleepTimer > 0 {
                    speakService.setSleepTimer(minutes: minutes)
                }
            }
        }
    }

    /// Provider-relative transport matching Android's bookmark/rewind/previous/stop/play/next/forward row.
    private var transportControls: some View {
        HStack(spacing: 0) {
            transportButton(
                "backward.end.fill",
                help: "rewind",
                disabled: !speakService.isSpeaking,
                action: speakService.rewind
            )
            transportButton(
                "backward.frame.fill",
                help: "speak_previous",
                disabled: !speakService.isSpeaking,
                action: speakService.previousUnit
            )
            transportButton(
                "stop.fill",
                help: "stop",
                disabled: !speakService.isSpeaking,
                action: speakService.stop
            )
            transportButton(
                speakService.isPaused || !speakService.isSpeaking ? "play.fill" : "pause.fill",
                help: speakService.isPaused || !speakService.isSpeaking ? "speak" : "pause"
            ) {
                if speakService.isPaused {
                    speakService.resume()
                } else if speakService.isSpeaking {
                    speakService.pause()
                } else {
                    speakService.play()
                }
            }
            transportButton(
                "forward.frame.fill",
                help: "speak_next",
                disabled: !speakService.isSpeaking,
                action: speakService.nextUnit
            )
            transportButton(
                "forward.end.fill",
                help: "forward",
                disabled: !speakService.isSpeaking,
                action: speakService.forward
            )
        }
        .frame(maxWidth: .infinity)
    }

    /// User-visible playback state label derived from the current speak-service state.
    private var stateLabel: String {
        if !speakService.isSpeaking { return String(localized: "speak_stopped") }
        if speakService.isPaused { return String(localized: "speak_paused") }
        return String(localized: "speak_playing")
    }

    /** Creates a stable-width icon transport button with a localized tooltip. */
    private func transportButton(
        _ systemName: String,
        help localizationKey: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(String(localized: String.LocalizationValue(localizationKey)))
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

    /** Builds a binding that persists one Android global advanced-speech boolean. */
    private func advancedBinding(_ keyPath: WritableKeyPath<AdvancedSpeakSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { speakService.advancedSettings[keyPath: keyPath] },
            set: { value in
                var advanced = speakService.advancedSettings
                advanced[keyPath: keyPath] = value
                speakService.updateAdvancedSettings(advanced)
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

}

/** Navigation destination matching Android's two `GridChoosePassageBook` passage picks. */
private struct SpeakVerseRangeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SpeakVerseRangeDraft
    @State private var searchText = ""
    @State private var rejectedSelection = false

    let onApply: (SpeakStreamPosition?, SpeakStreamPosition?) -> Bool

    /** Creates a fresh beginning-stage chooser over exact provider positions. */
    init(
        positions: [SpeakStreamPosition],
        onApply: @escaping (SpeakStreamPosition?, SpeakStreamPosition?) -> Bool
    ) {
        _draft = State(initialValue: SpeakVerseRangeDraft(positions: positions))
        self.onApply = onApply
    }

    /** Presents exact provider positions and advances from beginning to ending selection. */
    var body: some View {
        List(filteredPositions) { position in
            Button {
                select(position)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.keyName.isEmpty ? position.key : position.keyName)
                    if !position.bookName.isEmpty {
                        Text(position.bookName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(
            String(
                localized: draft.start == nil
                    ? "speak_beginning_of_passage"
                    : "speak_ending_of_passage"
            )
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
        }
        .overlay {
            if rejectedSelection {
                AndroidMyDocumentDecisionDialog(title: String(localized: "speak_ending_verse_must_be_later"), message: nil, actions: [
                    .init(id: "okay", title: String(localized: "ok"), style: .normal) { rejectedSelection = false }
                ])
            }
        }
    }

    /// Exact beginning/end candidates filtered only by user-visible source text.
    private var filteredPositions: [SpeakStreamPosition] {
        let candidates = draft.availablePositions
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.keyName.localizedCaseInsensitiveContains(query)
                || $0.key.localizedCaseInsensitiveContains(query)
                || $0.bookName.localizedCaseInsensitiveContains(query)
        }
    }

    /** Advances the draft or atomically applies the completed range through `SpeakService`. */
    private func select(_ position: SpeakStreamPosition) {
        searchText = ""
        switch draft.select(position) {
        case .awaitingEnd:
            return
        case .completed(let start, let end):
            if onApply(start, end) {
                dismiss()
            } else {
                rejectedSelection = true
            }
        case .invalid:
            rejectedSelection = true
        }
    }
}
