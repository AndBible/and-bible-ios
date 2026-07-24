// AndroidDailyReadingActivityView.swift -- App-owned Daily Reading activity presentation

import BibleCore
import SwiftUI

/// Flat two-line day row projected from Android's `DailyReadingItemAdapter` contract.
struct AndroidDailyReadingDayRow: Identifiable, Equatable {
    let id: UUID
    let dayNumber: Int
    let title: String
    let readings: String
}

/**
 Immutable reader-owned state for Android's Daily Reading action-bar document and speech controls.

 Android obtains these values from the active window page manager and global speech service. The
 presentation receives only labels and state; all mutations remain explicit parent callbacks.
 */
struct AndroidDailyReadingToolbarState: Equatable {
    /// Suggested active Bible abbreviation, or `nil` when no Bible is available.
    let bibleTitle: String?

    /// Suggested active commentary abbreviation, or `nil` when none is available.
    let commentaryTitle: String?

    /// Suggested active dictionary abbreviation, or `nil` when none is available.
    let dictionaryTitle: String?

    /// Whether Android's pause and stop actions should replace compact document actions.
    let isSpeaking: Bool

    /// Whether the speech toggle should show Resume instead of Pause.
    let isPaused: Bool

    /// Compatibility state for standalone previews and focused tests.
    static let unavailable = AndroidDailyReadingToolbarState(
        bibleTitle: nil,
        commentaryTitle: nil,
        dictionaryTitle: nil,
        isSpeaking: false,
        isPaused: false
    )
}

/** Pure Android action-budget projection used by Daily Reading presentation and tests. */
struct AndroidDailyReadingToolbarVisibility: Equatable {
    /// Whether Stop and Pause/Resume should be visible.
    let showsSpeechControls: Bool

    /// Whether the suggested dictionary action fits Android's wide-only rule.
    let showsDictionary: Bool

    /// Whether the suggested commentary action survives compact speech mode.
    let showsCommentary: Bool

    /**
     Resolves Android's `canShow` rules for one current layout and speech state.

     - Parameters:
       - isWide: Whether the action bar has Android's expanded-width budget.
       - isSpeaking: Whether speech mode is active.
       - hasDictionary: Whether a suggested dictionary exists.
       - hasCommentary: Whether a suggested commentary exists.
     - Returns: Deterministic visibility flags in source behavior.
     - Side effects: None.
     - Failure modes: None.
     */
    static func resolve(
        isWide: Bool,
        isSpeaking: Bool,
        hasDictionary: Bool,
        hasCommentary: Bool
    ) -> AndroidDailyReadingToolbarVisibility {
        AndroidDailyReadingToolbarVisibility(
            showsSpeechControls: isSpeaking,
            showsDictionary: isWide && hasDictionary,
            showsCommentary: hasCommentary && (isWide || !isSpeaking)
        )
    }
}

/**
 Applies Android's resource-sized character budget to one quick-document abbreviation.

 - Parameters:
   - title: Active document abbreviation.
   - isWide: Whether Android's seven-character expanded budget applies instead of four characters.
 - Returns: Prefix fitting the matching action-button budget.
 - Side effects: None.
 - Failure modes: None; empty input returns an empty string.
 */
func androidDailyReadingToolbarDocumentTitle(_ title: String, isWide: Bool) -> String {
    String(title.prefix(isWide ? 7 : 4))
}

/// Stable UI-state identity shared by the owner and Android reading-row presentation.
func androidDailyReadingActionKey(
    kind: DailyReadingActionKind,
    readingNumbers: [Int]
) -> String {
    "\(kind == .read ? "read" : "speak")::\(readingNumbers.map(String.init).joined(separator: "-"))"
}

/**
 Renders Android's custom-titlebar Daily Reading activity without persistence responsibilities.

 The owner supplies already-resolved plan/day/status values and explicit commands. This component
 owns only source layout: clickable plan/day titles, anchored overflow, top date text, table rows,
 the All/Speak row, and fixed Done button. It reuses shared activity, popup, checkbox, and raised
 button components instead of introducing feature-local substitutes.
 */
struct AndroidDailyReadingActivityView: View {
    let planName: String
    let dayNumber: Int
    let dayTitle: String
    let readingDate: String
    let readings: [String]
    let readStates: [Bool]
    let isReadingEditable: Bool
    let isDateBasedPlan: Bool
    let isBusy: Bool
    let activeActionKey: String?
    let toolbarState: AndroidDailyReadingToolbarState
    let surfacePalette: ReaderThemeSurfacePalette

    @Binding var showsOverflowMenu: Bool

    let onBack: () -> Void
    let onChoosePlan: () -> Void
    let onChooseDay: () -> Void
    let onOpenBible: () -> Void
    let onOpenCommentary: () -> Void
    let onOpenDictionary: () -> Void
    let onToggleSpeechPause: () -> Void
    let onStopSpeech: () -> Void
    let onToggleReading: (Int) -> Void
    let onPerformAction: (DailyReadingActionKind, [Int]) -> Void
    let onDone: () -> Void
    let onSetCurrentDay: () -> Void
    let onSetStartDate: () -> Void
    let onReset: () -> Void
    let onImport: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Builds the custom app bar, Android reading table, fixed action, and anchored popup.
    var body: some View {
        VStack(spacing: 0) {
            appBar
            content
        }
        .overlay(alignment: .topLeading) {
            AndroidActivityAccessibilityMarker(
                label: planName,
                accessibilityIdentifier: "dailyReadingScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: "dailyReadingOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 270,
            estimatedMenuHeight: isDateBasedPlan ? 100 : 204,
            accessibilityIdentifier: "dailyReadingOverflowMenu"
        ) { overflowMenu }
    }

    /// Android custom title bar with separate plan/day targets and shared overflow anchoring.
    private var appBar: some View {
        AndroidActivityTopAppBarLayout(
            accessibilityTitle: planName,
            accessibilityIdentifier: "dailyReadingAppBar",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            onBack: onBack,
            navigationAccessibilityIdentifier: "dailyReadingBackButton",
            barHeight: 64,
            contentSpacing: 2
        ) {
            HStack(spacing: 2) {
                Button {
                    showsOverflowMenu = false
                    onChoosePlan()
                } label: {
                    Text(planName)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dailyReadingPlanTitleButton")

                Button {
                    showsOverflowMenu = false
                    onChooseDay()
                } label: {
                    Text(dayTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dailyReadingDayTitleButton")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            actionBarControls

            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "dailyReadingActionsMenuButton",
                foregroundColor: surfacePalette.toolbarForegroundColor
            ) {
                showsOverflowMenu.toggle()
            }
            .androidPopupMenuAnchor(id: "dailyReadingOverflowAnchor")
        }
    }

    /**
     Android's dynamic action-bar controls in source order.

     Stop and pause appear only while speech owns the activity. Dictionary is wide-layout only;
     commentary is also removed from compact speech mode so Android's fixed action budget remains
     usable. Bible remains visible whenever an active Bible exists.
     */
    @ViewBuilder
    private var actionBarControls: some View {
        let visibility = AndroidDailyReadingToolbarVisibility.resolve(
            isWide: horizontalSizeClass == .regular,
            isSpeaking: toolbarState.isSpeaking,
            hasDictionary: toolbarState.dictionaryTitle != nil,
            hasCommentary: toolbarState.commentaryTitle != nil
        )
        if visibility.showsSpeechControls {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("SpeakStop"),
                accessibilityLabel: String(localized: "stop", defaultValue: "Stop"),
                accessibilityIdentifier: "dailyReadingStopSpeechButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: onStopSpeech
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset(toolbarState.isPaused ? "SpeakPlay" : "SpeakPause"),
                accessibilityLabel: toolbarState.isPaused
                    ? String(localized: "resume", defaultValue: "Resume")
                    : String(localized: "pause", defaultValue: "Pause"),
                accessibilityIdentifier: "dailyReadingPauseSpeechButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: onToggleSpeechPause
            )
        }

        if visibility.showsDictionary,
           let dictionaryTitle = toolbarState.dictionaryTitle {
            documentActionButton(
                title: dictionaryTitle,
                accessibilityLabel: String(localized: "dictionaries", defaultValue: "Dictionaries"),
                accessibilityIdentifier: "dailyReadingDictionaryButton",
                action: onOpenDictionary
            )
        }

        if visibility.showsCommentary,
           let commentaryTitle = toolbarState.commentaryTitle {
            documentActionButton(
                title: commentaryTitle,
                accessibilityLabel: String(localized: "commentaries", defaultValue: "Commentaries"),
                accessibilityIdentifier: "dailyReadingCommentaryButton",
                action: onOpenCommentary
            )
        }

        if let bibleTitle = toolbarState.bibleTitle {
            documentActionButton(
                title: bibleTitle,
                accessibilityLabel: String(localized: "bible", defaultValue: "Bible"),
                accessibilityIdentifier: "dailyReadingBibleButton",
                action: onOpenBible
            )
        }
    }

    /**
     Renders one Android `QuickDocumentChangeToolbarButton` as its abbreviated text action.

     - Parameters:
       - title: Suggested module abbreviation from the active reader window.
       - accessibilityLabel: Localized document-category label.
       - accessibilityIdentifier: Stable UI-test identity.
       - action: Parent-owned category switch followed by activity dismissal.
     - Returns: Shared app-bar text action with Android's compact character budget.
     - Side effects: Invokes `action` after a direct tap.
     - Failure modes: Empty labels render no text but retain their accessible category label.
     */
    private func documentActionButton(
        title: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidActivityTopAppBarTextActionButton(
            title: androidDailyReadingToolbarDocumentTitle(
                title,
                isWide: horizontalSizeClass == .regular
            ),
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            action: action
        )
    }

    /// Android top text, reading rows, All/Speak row, and fixed weighted Done button.
    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(planName)
                    .font(.system(size: 18))
                HStack {
                    Text(readingDate)
                    Spacer()
                    Text(dayTitle)
                        .accessibilityIdentifier("dailyReadingCurrentDayLabel")
                        .accessibilityValue("\(dayNumber)")
                }
                .font(.system(size: 18))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(readings.enumerated()), id: \.offset) { offset, passage in
                        readingRow(passage: passage, readingNumber: offset + 1)
                    }

                    if readings.count > 1 {
                        speakAllRow
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            HStack {
                Spacer(minLength: 0)
                AndroidRaisedTextButton(
                    title: String(localized: "done", defaultValue: "Done"),
                    foregroundColor: surfacePalette.foregroundColor,
                    backgroundColor: surfacePalette.controlFillColor,
                    isEnabled: allRead,
                    accessibilityIdentifier: "dailyReadingDoneButton",
                    action: onDone
                )
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Whether every source reading is explicitly marked read.
    private var allRead: Bool {
        !readings.isEmpty && readStates.count >= readings.count && readStates.prefix(readings.count).allSatisfy { $0 }
    }

    /// Android table row with shared checkbox indicator plus Passage and Speak raised commands.
    private func readingRow(passage: String, readingNumber: Int) -> some View {
        HStack(spacing: 6) {
            Button { onToggleReading(readingNumber) } label: {
                AndroidCheckboxIndicator(
                    isOn: readStates.indices.contains(readingNumber - 1)
                        ? readStates[readingNumber - 1]
                        : false,
                    uncheckedColor: surfacePalette.secondaryForegroundColor,
                    accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
                )
            }
            .buttonStyle(.plain)
            .disabled(!isReadingEditable)
            .accessibilityIdentifier("dailyReadingStatusToggle::\(readingNumber)")

            Text(passage)
                .font(.system(size: 17))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            actionButton(kind: .read, readingNumbers: [readingNumber])
                .frame(width: 86)
            actionButton(kind: .speak, readingNumbers: [readingNumber])
                .frame(width: 76)
        }
        .frame(minHeight: 52)
    }

    /// Android's final All row with only the Speak action visible.
    private var speakAllRow: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 30, height: 30)
            Text(String(localized: "all", defaultValue: "All"))
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 86, height: 1)
            actionButton(kind: .speak, readingNumbers: Array(1...readings.count), speaksAll: true)
                .frame(width: 76)
        }
        .frame(minHeight: 52)
    }

    /// Shared raised Passage, Speak, or Speak All command.
    private func actionButton(
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        speaksAll: Bool = false
    ) -> some View {
        let key = androidDailyReadingActionKey(kind: kind, readingNumbers: readingNumbers)
        let title = kind == .read
            ? String(localized: "selectPassage", defaultValue: "Passage")
            : String(localized: "speak", defaultValue: "Speak")
        return AndroidRaisedTextButton(
            title: title,
            foregroundColor: surfacePalette.foregroundColor,
            backgroundColor: surfacePalette.controlFillColor,
            isEnabled: !isBusy,
            isRunning: activeActionKey == key,
            accessibilityIdentifier: "dailyReading\(kind == .read ? "Read" : (speaksAll ? "SpeakAll" : "Speak"))Button::\(readingNumbers.map(String.init).joined(separator: "-"))"
        ) {
            onPerformAction(kind, readingNumbers)
        }
    }

    /// Source-order Android overflow commands, including the source group divider before Import.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "dailyReadingOverflowMenuSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                if !isDateBasedPlan {
                    AndroidPopupMenuRow(
                        title: String(localized: "set_current_day", defaultValue: "Set as current day…"),
                        accessibilityIdentifier: "dailyReadingSetCurrentDayButton"
                    ) {
                        showsOverflowMenu = false
                        onSetCurrentDay()
                    }
                    AndroidPopupMenuRow(
                        title: String(localized: "rdg_plan_set_start_date", defaultValue: "Set Start Date…"),
                        accessibilityIdentifier: "dailyReadingSetStartDateButton"
                    ) {
                        showsOverflowMenu = false
                        onSetStartDate()
                    }
                }
                AndroidPopupMenuRow(
                    title: String(localized: "reset_generic", defaultValue: "Reset"),
                    icon: .asset("ActivityReset"),
                    accessibilityIdentifier: "dailyReadingResetPlanButton"
                ) {
                    showsOverflowMenu = false
                    onReset()
                }
                Divider().overlay(surfacePalette.inactiveBorderColor)
                AndroidPopupMenuRow(
                    title: String(localized: "import_reading_plan", defaultValue: "Import reading plan…"),
                    accessibilityIdentifier: "readingPlanImportButton"
                ) {
                    showsOverflowMenu = false
                    onImport()
                }
            }
        }
    }
}

/** Renders Android's `DailyReadingList` app bar and flat two-line day rows. */
struct AndroidDailyReadingDaySelectorView: View {
    let rows: [AndroidDailyReadingDayRow]
    let surfacePalette: ReaderThemeSurfacePalette
    let onBack: () -> Void
    let onSelect: (Int) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "rdg_plan_title", defaultValue: "Reading Plan"),
                accessibilityIdentifier: "dailyReadingDaySelectorAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                EmptyView()
            } content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button { onSelect(row.dayNumber) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).font(.system(size: 18))
                                    Text(row.readings)
                                        .font(.system(size: 16))
                                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("dailyReadingDayButton::\(row.dayNumber)")
                            Divider().overlay(surfacePalette.inactiveBorderColor)
                        }
                    }
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "rdg_plan_title", defaultValue: "Reading Plan"),
                accessibilityIdentifier: "dailyReadingDaySelectorScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
    }
}
