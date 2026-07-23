import BibleCore
import SwiftUI

enum ReadingProgressTab: Int, CaseIterable, Identifiable {
    case reading = 0
    case memorization = 1

    init(androidTab: Int) {
        self = androidTab == 1 ? .memorization : .reading
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .reading:
            return String(localized: "memorize_tab_reading", defaultValue: "Reading")
        case .memorization:
            return String(localized: "memorize_tab_memorization", defaultValue: "Memorization")
        }
    }
}

struct ChapterReadHistoryTarget: Equatable {
    let bookInitials: String
    let startOrdinal: Int
    let kjvBookOrdinal: Int
    let bookName: String
    let chapter: Int
}

private struct ReadingProgressPersistenceFailure: Identifiable {
    let id = UUID()
}

/**
 Owns Android ReadingProgressActivity's reading/memorization state and data-driven content.

 Presentation is delegated to shared app-owned activity, tab, popup, dialog, and progress controls;
 this type reads immutable store snapshots and mutates them only after explicit Android-equivalent
 actions. Book/day/chapter history is presented through the shared staged-delete dialog instead of
 an invented inline section or native iOS navigation surface.

 Inputs: captured progress stores, launching reader palette, initial tab, navigation commands, and
 reader content-opening callbacks

 Output: one full-screen app-owned Read/Memory Progress activity

 Side effects: persists tab selection, cycle changes, memorization removals, and staged history
 deletions through the supplied stores

 Failure modes: persistence failures keep the current activity visible and present the shared
 Android error dialog
 */
struct ReadingProgressView: View {
    let readingStore: ReadingProgressStore?
    let memorizationStore: MemorizationProgressStore?
    let surfacePalette: ReaderThemeSurfacePalette
    let onBack: () -> Void
    let onOpenSettings: (() -> Void)?
    let onOpenMemorizeRange: (MemorizationProgressRange) -> Void
    let onOpenChapter: (String, Int) -> Void

    /// Active scheme used only for the shared AppCompat accent.
    @Environment(\.colorScheme) private var colorScheme
    /// Android's persisted tab used when an activity launch does not carry an explicit tab extra.
    @AppStorage("reading_progress_last_tab") private var persistedTabRawValue = ReadingProgressTab.reading.rawValue
    @State private var selectedTab: ReadingProgressTab
    @AppStorage("reading_progress_mem_overview") private var memorizationOverviewActive = true
    @State private var memorizationRevision = 0
    @State private var memorizedPassagesShown = 10
    @State private var targetsShown = 10
    @State private var selectedMemorizationBookOsisId: String?
    @State private var memorizationDeletionRequest: MemorizationDeletionRequest?
    @State private var readingRevision = 0
    @State private var selectedReadingBookOrdinal: Int?
    @State private var bibleOverviewScrollRevision = 0
    @State private var readHistorySelection: AndroidReadHistorySelection?
    @State private var showNewReadingCycleConfirmation = false
    @State private var persistenceFailure: ReadingProgressPersistenceFailure?
    @State private var isHelpPresented = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(
        readingStore: ReadingProgressStore?,
        memorizationStore: MemorizationProgressStore?,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        initialTab: ReadingProgressTab? = nil,
        onBack: @escaping () -> Void = {},
        onOpenSettings: (() -> Void)? = nil,
        onOpenMemorizeRange: @escaping (MemorizationProgressRange) -> Void = { _ in },
        onOpenChapter: @escaping (String, Int) -> Void = { _, _ in }
    ) {
        self.readingStore = readingStore
        self.memorizationStore = memorizationStore
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
        self.onOpenMemorizeRange = onOpenMemorizeRange
        self.onOpenChapter = onOpenChapter
        let persistedTab = ReadingProgressTab(
            rawValue: UserDefaults.standard.integer(forKey: "reading_progress_last_tab")
        ) ?? .reading
        _selectedTab = State(initialValue: initialTab ?? persistedTab)
    }

    var body: some View {
        AndroidReadingProgressActivityView(
            surfacePalette: surfacePalette,
            selectedTab: $selectedTab,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onOpenHelp: { isHelpPresented = true },
            scrollToBibleOverviewRevision: bibleOverviewScrollRevision
        ) {
            switch selectedTab {
            case .reading:
                readingSection
            case .memorization:
                memorizationSection
            }
        }
        .onAppear {
            persistedTabRawValue = selectedTab.rawValue
        }
        .onChange(of: selectedTab) { _, tab in
            persistedTabRawValue = tab.rawValue
            if tab == .reading {
                memorizedPassagesShown = 10
                targetsShown = 10
            } else {
                selectedMemorizationBookOsisId = nil
            }
        }
        .onChange(of: memorizationOverviewActive) { _, overviewActive in
            if overviewActive {
                selectedMemorizationBookOsisId = nil
            }
        }
        .overlay {
            if let selection = readHistorySelection {
                AndroidReadHistoryDialog(
                    store: readingStore,
                    selection: selection,
                    onDismiss: { readHistorySelection = nil },
                    onChanged: { readingRevision += 1 }
                )
            } else if let request = memorizationDeletionRequest {
                AndroidDecisionDialog(
                    title: "",
                    message: request.message,
                    actions: [
                        .init(
                            id: "cancel",
                            title: String(localized: "cancel", defaultValue: "Cancel"),
                            style: .normal
                        ) { memorizationDeletionRequest = nil },
                        .init(
                            id: "confirm",
                            title: String(localized: "okay", defaultValue: "OK"),
                            style: .normal
                        ) {
                            performMemorizationDeletion(request)
                            memorizationDeletionRequest = nil
                        },
                    ],
                    accessibilityIdentifier: "androidReadingProgressDecisionDialog"
                )
            } else if persistenceFailure != nil {
                AndroidDecisionDialog(
                    title: String(localized: "reading_progress_save_failed", defaultValue: "Unable to save progress"),
                    message: String(localized: "reading_progress_save_failed_message", defaultValue: "Your existing progress was left unchanged. Try again."),
                    actions: [
                        .init(
                            id: "okay",
                            title: String(localized: "okay", defaultValue: "OK"),
                            style: .normal
                        ) { persistenceFailure = nil },
                    ],
                    accessibilityIdentifier: "androidReadingProgressDecisionDialog"
                )
            } else if isHelpPresented {
                AndroidHelpDialog(
                    featureMessage: String(
                        localized: "help_reading_progress_text",
                        defaultValue: "Your Bible reading and memorization progress at a glance. Mark chapters as read manually with the \"Mark as read\" button, or enable automatic tracking. Memorize exercises also feed into this view."
                    ),
                    documentationURL: URL(
                        string: "https://docs.andbible.org/en/latest/reading_progress.html"
                    ),
                    onDismiss: { isHelpPresented = false }
                )
            } else if showNewReadingCycleConfirmation {
                AndroidDecisionDialog(
                    title: String(localized: "reading_progress_new_cycle", defaultValue: "New Cycle"),
                    message: String(localized: "reading_progress_new_cycle_confirm", defaultValue: "Start a new reading cycle? This will begin tracking your progress from scratch, while preserving your previous cycle's data."),
                    actions: [
                        .init(
                            id: "cancel",
                            title: String(localized: "cancel", defaultValue: "Cancel"),
                            style: .normal
                        ) { showNewReadingCycleConfirmation = false },
                        .init(
                            id: "newCycle",
                            title: String(localized: "okay", defaultValue: "OK"),
                            style: .normal
                        ) {
                            showNewReadingCycleConfirmation = false
                            do {
                                _ = try readingStore?.startNewCycle()
                                readingRevision += 1
                            } catch {
                                persistenceFailure = ReadingProgressPersistenceFailure()
                            }
                        },
                    ],
                    accessibilityIdentifier: "androidReadingProgressDecisionDialog"
                )
            }
        }
    }

    @ViewBuilder
    private var readingSection: some View {
        let presentation = readingStore?.presentation(recentLimit: .max) ?? ReadingProgressPresentationSnapshot(
            cycle: 1,
            latestCycle: 1,
            distinctChapterCount: 0,
            activeDayCount: 0,
            totalBibleChapterCount: 1_189,
            books: [],
            calendar: [],
            recentRows: []
        )

        VStack(alignment: .leading, spacing: 0) {
            ReadingProgressSummaryCounters(
                leadingValue: "\(presentation.distinctChapterCount)",
                leadingLabel: String(
                    localized: "reading_progress_chapters_read",
                    defaultValue: "chapters read"
                ),
                trailingValue: "\(presentation.activeDayCount)",
                trailingLabel: String(
                    localized: "reading_progress_active_days",
                    defaultValue: "active days"
                )
            )
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 4) {
                AndroidDeterminateProgressIndicator(
                    fraction: presentation.overallProgress,
                    trackColor: surfacePalette.inactiveBorderColor,
                    accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
                )
                Text(String(
                    format: String(
                        localized: "reading_progress_overall",
                        defaultValue: "%@%% of Bible read"
                    ),
                    String(format: "%.1f", presentation.overallPercent)
                ))
                .font(.system(size: 12))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.bottom, 16)

            Text(String(
                localized: "reading_progress_bible_heatmap",
                defaultValue: "Bible Overview"
            ))
            .font(.system(size: 16, weight: .bold))
            .padding(.bottom, 8)
            .id(AndroidReadingProgressScrollTarget.bibleOverview)

            readingBookSections(presentation)

            Text(String(
                localized: "reading_progress_calendar",
                defaultValue: "Reading Activity"
            ))
            .font(.system(size: 16, weight: .bold))
            .padding(.bottom, 8)

            ReadingProgressCalendarHeatmap(counts: presentation.calendar) { dayMilliseconds in
                readHistorySelection = .day(startMilliseconds: dayMilliseconds)
            }
            .padding(.bottom, 16)

            readingCycleControls(presentation)
        }
        .id(readingRevision)
    }

    /**
     Renders Android's Old/New Testament book heatmaps and selected chapter counts.

     Direct taps drill into chapters; mutually exclusive long presses open the shared book/chapter
     history dialog without also firing the navigation command.
     */
    @ViewBuilder
    private func readingBookSections(_ presentation: ReadingProgressPresentationSnapshot) -> some View {
        let effectiveMaximum = AndroidReadingProgressHeatmap.effectiveBookScaleMaximum(
            presentation.books.map(\.readPercent).max()
        )
        let groups = [
            (
                String(localized: "reading_progress_old_testament", defaultValue: "Old Testament"),
                presentation.books.filter { !$0.book.isNewTestament }
            ),
            (
                String(localized: "reading_progress_new_testament", defaultValue: "New Testament"),
                presentation.books.filter(\.book.isNewTestament)
            ),
        ]
        VStack(alignment: .leading, spacing: 0) {
            ReadingProgressBookScale(
                effectiveMaximum: effectiveMaximum,
                secondaryTextColor: surfacePalette.secondaryForegroundColor
            )
            .padding(.bottom, 8)

            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Text(group.0)
                    .font(.system(size: 13, weight: .bold))
                    .padding(.bottom, 4)
                ReadingProgressBookHeatmap(
                    books: group.1,
                    effectiveMaximum: effectiveMaximum,
                    selectedBookOrdinal: Binding(
                        get: { selectedReadingBookOrdinal },
                        set: { ordinal in
                            selectedReadingBookOrdinal = ordinal
                            if ordinal != nil {
                                bibleOverviewScrollRevision &+= 1
                            }
                        }
                    ),
                    onOpenHistory: { book in
                        readHistorySelection = .book(
                            kjvBookOrdinal: book.book.bibleBookOrdinal,
                            longName: book.book.longName
                        )
                    }
                )
                .padding(.bottom, index == groups.count - 1 ? 16 : 12)
            }

            if let selectedReadingBookOrdinal,
               let selectedBook = presentation.books.first(where: {
                   $0.book.bibleBookOrdinal == selectedReadingBookOrdinal
               }) {
                Text(selectedBook.book.longName)
                    .font(.system(size: 14, weight: .bold))
                    .padding(.bottom, 4)
                ReadingProgressChapterHeatmap(
                    book: selectedBook,
                    secondaryTextColor: surfacePalette.secondaryForegroundColor,
                    onOpenChapter: onOpenChapter,
                    onOpenHistory: { chapter in
                        readHistorySelection = .chapter(ChapterReadHistoryTarget(
                            bookInitials: "",
                            startOrdinal: 0,
                            kjvBookOrdinal: selectedBook.book.bibleBookOrdinal,
                            bookName: selectedBook.book.longName,
                            chapter: chapter
                        ))
                    }
                )
                .padding(.bottom, 16)
            }
        }
    }

    /** Builds Android's bottom-of-content cycle selector and New Cycle text command. */
    private func readingCycleControls(
        _ presentation: ReadingProgressPresentationSnapshot
    ) -> some View {
        HStack(spacing: 8) {
            cycleButton(
                assetName: "ProgressCyclePrevious",
                accessibilityLabel: String(
                    localized: "reading_progress_previous_cycle",
                    defaultValue: "Previous cycle"
                ),
                isEnabled: presentation.cycle > 1
            ) {
                selectReadingCycle(max(presentation.cycle - 1, 1))
            }

            Text(String(
                format: String(localized: "reading_progress_cycle", defaultValue: "Cycle %d"),
                presentation.cycle
            ))
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .center)

            cycleButton(
                assetName: "ProgressCycleNext",
                accessibilityLabel: String(
                    localized: "reading_progress_next_cycle",
                    defaultValue: "Next cycle"
                ),
                isEnabled: presentation.cycle < presentation.latestCycle
            ) {
                selectReadingCycle(presentation.cycle + 1)
            }

            if presentation.cycle >= presentation.latestCycle {
                Button(
                    String(
                        localized: "reading_progress_new_cycle",
                        defaultValue: "New Cycle"
                    )
                ) {
                    showNewReadingCycleConfirmation = true
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                .buttonStyle(.plain)
                .frame(minHeight: 40)
                .accessibilityIdentifier("readingProgressNewCycleButton")
            }
        }
    }

    /** Builds one exact ported Android cycle-arrow control with disabled alpha behavior. */
    private func cycleButton(
        assetName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            AndBibleIconView(name: assetName, size: 24)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidResourcePalette.grey500)
        .opacity(isEnabled ? 1 : 0.3)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
    }

    /** Selects an existing Android reading cycle and clears drill-down filters. */
    private func selectReadingCycle(_ cycle: Int) {
        do {
            _ = try readingStore?.setActiveCycle(cycle)
            readingRevision += 1
        } catch {
            persistenceFailure = ReadingProgressPersistenceFailure()
        }
    }

    @ViewBuilder
    private var memorizationSection: some View {
        let snapshot = memorizationStore?.snapshot() ?? MemorizationProgressSnapshot()
        let presentation = MemorizationProgressPresentation(snapshot: snapshot)

        VStack(alignment: .leading, spacing: 0) {
            ReadingProgressSummaryCounters(
                leadingValue: "\(presentation.summary.totalMemorized)",
                leadingLabel: String(
                    localized: "memorize_verses_memorized",
                    defaultValue: "Memorized"
                ),
                trailingValue: presentation.summary.targetTotal > 0
                    ? "\(presentation.summary.targetTotal)"
                    : "-",
                trailingLabel: String(
                    localized: "memorize_verses_target",
                    defaultValue: "Goal"
                )
            )
            .padding(.bottom, 16)

            if presentation.summary.targetTotal > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    AndroidDeterminateProgressIndicator(
                        fraction: Double(presentation.summary.targetMemorized)
                            / Double(presentation.summary.targetTotal),
                        trackColor: surfacePalette.inactiveBorderColor,
                        accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
                    )
                    Text(targetProgressLabel(
                        memorized: presentation.summary.targetMemorized,
                        total: presentation.summary.targetTotal
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.bottom, 16)
            }

            MemorizationViewToggle(overviewActive: $memorizationOverviewActive)
                .padding(.bottom, 16)

            if memorizationOverviewActive {
                memorizationOverviewSections(presentation)
            } else {
                memorizationListSections(presentation)
            }
        }
        .id(memorizationRevision)
    }

    @ViewBuilder
    private func memorizationListSections(_ presentation: MemorizationProgressPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                progressSectionTitle(String(
                    localized: "memorize_memorized_passages",
                    defaultValue: "Memorized passages"
                ), textSize: 16)
                if presentation.memorizedPassages.isEmpty {
                    Text(String(localized: "memorize_no_memorized_passages", defaultValue: "No memorized passages yet"))
                        .font(.system(size: 13))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(presentation.memorizedPassages.prefix(memorizedPassagesShown))) { passage in
                            memorizedPassageRow(passage)
                        }
                        if presentation.memorizedPassages.count > memorizedPassagesShown {
                            Button(showMoreTitle(remaining: presentation.memorizedPassages.count - memorizedPassagesShown)) {
                                memorizedPassagesShown += 10
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 8) {
                progressSectionTitle(String(
                    localized: "memorize_targets",
                    defaultValue: "Memorization goals"
                ), textSize: 16)
                if presentation.incompleteTargets.isEmpty {
                    Text(String(localized: "memorize_no_targets", defaultValue: "No memorization goals set"))
                        .font(.system(size: 13))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(presentation.incompleteTargets.prefix(targetsShown))) { item in
                            memorizationTargetRow(item)
                        }
                        if presentation.incompleteTargets.count > targetsShown {
                            Button(showMoreTitle(remaining: presentation.incompleteTargets.count - targetsShown)) {
                                targetsShown += 10
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memorizationOverviewSections(_ presentation: MemorizationProgressPresentation) -> some View {
        let oldTestamentBooks = presentation.books.filter { !$0.isNewTestament }
        let newTestamentBooks = presentation.books.filter(\.isNewTestament)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                progressSectionTitle(String(
                    localized: "reading_progress_old_testament",
                    defaultValue: "Old Testament"
                ), textSize: 13)
                MemorizationBookGridView(
                    books: oldTestamentBooks
                ) { osisId in
                    selectedMemorizationBookOsisId = osisId
                }
            }
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 4) {
                progressSectionTitle(String(
                    localized: "reading_progress_new_testament",
                    defaultValue: "New Testament"
                ), textSize: 13)
                MemorizationBookGridView(
                    books: newTestamentBooks
                ) { osisId in
                    selectedMemorizationBookOsisId = osisId
                }
            }
            .padding(.bottom, 16)

            if let selectedMemorizationBookOsisId,
               let detail = presentation.chapterDetail(osisId: selectedMemorizationBookOsisId) {
                VStack(alignment: .leading, spacing: 4) {
                    progressSectionTitle(detail.title, textSize: 14)
                    MemorizationChapterGridView(detail: detail, onOpenChapter: onOpenChapter)
                }
                .padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 8) {
                progressSectionTitle(String(
                    localized: "memorize_calendar",
                    defaultValue: "Memorization Activity"
                ), textSize: 16)
                MemorizationCalendarView(counts: presentation.calendarCountsByDayStartMilliseconds)
            }
        }
    }

    /** Builds one Android XML-sized heading without iOS `Section` list chrome. */
    private func progressSectionTitle(_ title: String, textSize: CGFloat) -> some View {
        Text(title)
            .font(.system(size: textSize, weight: .bold))
            .foregroundStyle(surfacePalette.foregroundColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memorizedPassageRow(
        _ passage: MemorizationProgressPresentation.MemorizedPassage
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(passage.title)
                    .font(.system(size: 14))
                Text(relativeDateText(milliseconds: passage.latestMemorizedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
            }
            Spacer(minLength: 8)
            Button {
                memorizationDeletionRequest = MemorizationDeletionRequest(
                    message: removeMemorizedPassageConfirmationTitle(passage.title),
                    kind: .memorizedPassage(passage)
                )
            } label: {
                Text("×")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(surfacePalette.foregroundColor)
            .accessibilityLabel(String(localized: "remove", defaultValue: "Remove"))
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenMemorizeRange(passage.range)
        }
    }

    private func memorizationTargetRow(
        _ item: MemorizationProgressPresentation.TargetItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.title) (\(item.memorizedCount)/\(item.verseCount))")
                        .font(.system(size: 14))
                    Text(relativeDateText(milliseconds: item.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                }
                Spacer(minLength: 8)
                Button {
                    memorizationDeletionRequest = MemorizationDeletionRequest(
                        message: removeMemorizationTargetConfirmationTitle(item.title),
                        kind: .target(item)
                    )
                } label: {
                    Text("×")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(surfacePalette.foregroundColor)
                .accessibilityLabel(String(localized: "remove", defaultValue: "Remove"))
            }
            AndroidDeterminateProgressIndicator(
                fraction: item.progressFraction,
                trackColor: surfacePalette.inactiveBorderColor,
                accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme)
            )
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenMemorizeRange(item.row.range)
        }
    }

    private func performMemorizationDeletion(_ request: MemorizationDeletionRequest) {
        guard let memorizationStore else { return }
        do {
            switch request.kind {
            case .memorizedPassage(let passage):
                _ = try memorizationStore.unmarkMemorized(
                    bookInitials: "",
                    startOrdinal: passage.range.startOrdinal,
                    endOrdinal: passage.range.endOrdinal
                )
            case .target(let item):
                _ = try memorizationStore.removeMemorizationTarget(id: item.id)
            }
            memorizationRevision += 1
        } catch {
            persistenceFailure = ReadingProgressPersistenceFailure()
        }
    }

    private func relativeDateText(milliseconds: Int64) -> String {
        guard milliseconds > 0 else {
            return String(localized: "date_unknown", defaultValue: "Date unknown")
        }
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    /**
     Formats Android's target-progress summary label.

     - Parameters:
       - memorized: Count of memorized ordinals inside target rows.
       - total: Total target ordinals counted by Android row semantics.
     - Returns: A percentage plus `memorized/total` ratio, matching Android's `%.0f%% (%d/%d)`.
     - Side effects: None.
     - Failure modes: Returns an empty string for zero totals; callers hide the label in that case.
     */
    private func targetProgressLabel(memorized: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        let percent = Double(memorized) * 100.0 / Double(total)
        return String(format: "%.0f%% (%d/%d)", percent, memorized, total)
    }

    /**
     Formats Android's paged list expansion label.

     - Parameter remaining: Number of undisplayed rows in the current list section.
     - Returns: Localized `Show %d more` title capped to the Android page size of ten.
     - Side effects: None.
     - Failure modes: Negative inputs are treated as zero.
     */
    private func showMoreTitle(remaining: Int) -> String {
        let count = min(max(remaining, 0), 10)
        let format = String(localized: "memorize_show_more", defaultValue: "Show %d more")
        return String(format: format, count)
    }

    /**
     Formats Android's named unmark confirmation prompt.

     - Parameter title: Passage title shown in the memorized-passage list row.
     - Returns: Localized confirmation string containing the affected passage title.
     - Side effects: None.
     - Failure modes: None.
     */
    private func removeMemorizedPassageConfirmationTitle(_ title: String) -> String {
        let format = String(localized: "memorize_confirm_unmark", defaultValue: "Remove memorized status for %@?")
        return String(format: format, title)
    }

    /**
     Formats Android's named target-removal confirmation prompt.

     - Parameter title: Target range title shown in the memorization-goal list row.
     - Returns: Localized confirmation string containing the affected goal title.
     - Side effects: None.
     - Failure modes: None.
     */
    private func removeMemorizationTargetConfirmationTitle(_ title: String) -> String {
        let format = String(localized: "memorize_confirm_remove_target", defaultValue: "Remove memorization goal %@?")
        return String(format: format, title)
    }
}

/**
 Renders the equal-width two-counter summary shared by Android's Reading and Memorization tabs.

 Inputs are preformatted values and localized labels; the component owns only the 28sp/12sp
 typography, centered geometry, and twelve-point padding defined by `reading_progress.xml`.
 */
private struct ReadingProgressSummaryCounters: View {
    let leadingValue: String
    let leadingLabel: String
    let trailingValue: String
    let trailingLabel: String

    var body: some View {
        HStack(spacing: 0) {
            summaryColumn(
                value: leadingValue,
                label: leadingLabel
            )
            summaryColumn(
                value: trailingValue,
                label: trailingLabel
            )
        }
    }

    private func summaryColumn(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
            Text(label)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }
}

private struct MemorizationViewToggle: View {
    @Binding var overviewActive: Bool

    /// Active scheme used by Android's borderless-button text accent.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Button(String(localized: "memorize_view_overview", defaultValue: "Overview")) {
                overviewActive = true
            }
            .font(.system(size: 14, weight: overviewActive ? .bold : .regular))
            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
            .frame(maxWidth: .infinity, minHeight: 48)
            .buttonStyle(.plain)

            Button(String(localized: "memorize_view_list", defaultValue: "List")) {
                overviewActive = false
            }
            .font(.system(size: 14, weight: overviewActive ? .regular : .bold))
            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
            .frame(maxWidth: .infinity, minHeight: 48)
            .buttonStyle(.plain)
        }
    }
}

private struct MemorizationDeletionRequest: Identifiable {
    enum Kind {
        case memorizedPassage(MemorizationProgressPresentation.MemorizedPassage)
        case target(MemorizationProgressPresentation.TargetItem)
    }

    let id = UUID()
    let message: String
    let kind: Kind
}

private struct MemorizationBookGridView: View {
    let books: [MemorizationProgressPresentation.BookCell]
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(books) { book in
                Button {
                    onSelect(book.osisId)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Text(book.shortTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                        if book.hasTarget {
                            Circle()
                                .fill(AndroidReadingProgressColor.targetDot)
                                .frame(width: 5, height: 5)
                                .padding(2)
                        }
                    }
                    .foregroundStyle(AndroidReadingProgressColor.memorizationTextColor(progress: book.progressFraction))
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AndroidReadingProgressColor.memorizationProgressColor(for: book.progressBucket))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(book.title)
            }
        }
    }
}

private struct MemorizationChapterGridView: View {
    let detail: MemorizationProgressPresentation.ChapterDetail
    let onOpenChapter: (String, Int) -> Void

    /// Android memorization detail retains the XML grid's fixed ten columns.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(detail.chapters) { chapter in
                Button {
                    onOpenChapter(detail.osisId, chapter.chapter)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Text("\(chapter.chapter)")
                            .font(.system(size: 12))
                            .padding(6)
                            .frame(minWidth: 36, maxWidth: .infinity)
                        if chapter.hasTarget {
                            Circle()
                                .fill(AndroidReadingProgressColor.targetDot)
                                .frame(width: 5, height: 5)
                                .padding(2)
                        }
                    }
                    .foregroundStyle(AndroidReadingProgressColor.memorizationTextColor(progress: chapter.progressFraction))
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AndroidReadingProgressColor.memorizationProgressColor(for: chapter.progressBucket))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(detail.title) \(chapter.chapter)")
            }
        }
    }
}

private struct MemorizationCalendarView: View {
    let counts: [Int64: Int]
    private let calendar = Calendar.current
    private let cellSize: CGFloat = 14
    private let cellPadding: CGFloat = 2
    private let labelWidth: CGFloat = 24
    private let headerHeight: CGFloat = 16

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: cellPadding) {
                        Color.clear
                            .frame(width: labelWidth, height: headerHeight)
                        ForEach(0..<7, id: \.self) { dayIndex in
                            dayLabel(for: dayIndex)
                                .font(.system(size: 10))
                                .foregroundStyle(AndroidResourcePalette.gray)
                                .frame(width: labelWidth, height: cellSize, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                Text(monthLabel(forWeek: weekIndex))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AndroidResourcePalette.gray)
                                    .frame(width: cellSize, height: headerHeight, alignment: .leading)
                                    .lineLimit(1)
                            }
                        }

                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                VStack(spacing: cellPadding) {
                                    ForEach(0..<7, id: \.self) { dayIndex in
                                        if let day = calendarDay(weekIndex: weekIndex, dayIndex: dayIndex) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(calendarColor(for: day))
                                                .frame(width: cellSize, height: cellSize)
                                                .accessibilityLabel(accessibilityLabel(for: day))
                                        } else {
                                            Color.clear
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                                .id(weekIndex)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear {
                proxy.scrollTo(52, anchor: .trailing)
            }
        }
    }

    private var calendarStart: Date {
        let today = calendar.startOfDay(for: Date())
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return calendar.date(byAdding: .weekOfYear, value: -52, to: currentWeekStart) ?? currentWeekStart
    }

    private func calendarColor(for day: Date) -> Color {
        let maxCount = max(counts.values.max() ?? 1, 1)
        let count = counts[dayStartMilliseconds(day), default: 0]
        return AndroidReadingProgressColor.memorizationCalendarColor(count: count, maxCount: maxCount)
    }

    private func calendarDay(weekIndex: Int, dayIndex: Int) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: weekIndex * 7 + dayIndex, to: calendarStart) else {
            return nil
        }
        let today = calendar.startOfDay(for: Date())
        return day <= today ? day : nil
    }

    @ViewBuilder
    private func dayLabel(for dayIndex: Int) -> some View {
        switch dayIndex {
        case 1:
            Text("M")
        case 3:
            Text("W")
        case 5:
            Text("F")
        default:
            Text("")
        }
    }

    private func monthLabel(forWeek weekIndex: Int) -> String {
        guard let day = calendarDay(weekIndex: weekIndex, dayIndex: 0) else {
            return ""
        }
        if weekIndex > 0,
           let previousWeek = calendarDay(weekIndex: weekIndex - 1, dayIndex: 0),
           calendar.component(.month, from: previousWeek) == calendar.component(.month, from: day) {
            return ""
        }
        return day.formatted(.dateTime.month(.abbreviated))
    }

    private func accessibilityLabel(for day: Date) -> String {
        let count = counts[dayStartMilliseconds(day), default: 0]
        let formattedDay = day.formatted(date: .abbreviated, time: .omitted)
        return "\(formattedDay), \(count)"
    }

    private func dayStartMilliseconds(_ day: Date) -> Int64 {
        let start = calendar.startOfDay(for: day)
        return (try? AndroidTimestamp.milliseconds(from: start))
            ?? (start.timeIntervalSince1970.sign == .minus ? .min : .max)
    }
}

private enum AndroidReadingProgressColor {
    static let targetDot = rgb(0x9C, 0x27, 0xB0)
    static let readingDarkText = rgb(0x44, 0x44, 0x44)

    private static let empty = rgb(0xE8, 0xE8, 0xE8)
    private static let memLow = rgb(0xC6, 0xE4, 0x8B)
    private static let memMedium = rgb(0x7B, 0xC9, 0x6F)
    private static let memHigh = rgb(0x23, 0x9A, 0x3B)
    private static let memFull = rgb(0x19, 0x61, 0x27)
    private static let darkGray = rgb(0x44, 0x44, 0x44)
    private static let calendarLevelColors: [Color] = [
        rgb(0xEB, 0xED, 0xF0),
        rgb(0x9B, 0xE9, 0xA8),
        rgb(0x40, 0xC4, 0x63),
        rgb(0x30, 0xA1, 0x4E),
        rgb(0x21, 0x6E, 0x39),
    ]

    static func memorizationProgressColor(for bucket: MemorizationProgressBucket) -> Color {
        switch bucket {
        case .empty:
            return empty
        case .low:
            return memLow
        case .medium:
            return memMedium
        case .high:
            return memHigh
        case .full:
            return memFull
        }
    }

    static func memorizationTextColor(progress: Double) -> Color {
        progress >= 1 ? .white : darkGray
    }

    static func memorizationCalendarColor(count: Int, maxCount: Int) -> Color {
        guard count > 0 else {
            return calendarLevelColors[0]
        }
        let fraction = Double(count) / Double(max(maxCount, 1))
        switch fraction {
        case ...0.25:
            return calendarLevelColors[1]
        case ...0.50:
            return calendarLevelColors[2]
        case ...0.75:
            return calendarLevelColors[3]
        default:
            return calendarLevelColors[4]
        }
    }

    /** Converts Android's packed ARGB contract value into a SwiftUI color. */
    static func readingColor(argb: UInt32) -> Color {
        Color(
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0
        )
    }
}

/** Android percentage legend for the repeat-read book heatmap. */
private struct ReadingProgressBookScale: View {
    /// Dynamic Android scale maximum, where `1` represents 100 percent.
    let effectiveMaximum: Double

    /// Launching activity's `textColorSecondary` projection.
    let secondaryTextColor: Color

    /** Builds Android's fixed 25-percent color bands through the effective maximum. */
    var body: some View {
        let percentages = AndroidReadingProgressHeatmap.bookScalePercentages(
            maximumReadPercent: effectiveMaximum
        )
        HStack(alignment: .center, spacing: 6) {
            Text(String(localized: "reading_progress_percent_read_scale", defaultValue: "Percent\nRead"))
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
                .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(percentages, id: \.self) { percentage in
                        Rectangle()
                            .fill(AndroidReadingProgressColor.readingColor(
                                argb: AndroidReadingProgressHeatmap.bookARGB(
                                    readPercent: Double(percentage) / 100,
                                    effectiveMaximum: effectiveMaximum
                                )
                            ))
                    }
                }
                .frame(height: 9)
                HStack(spacing: 0) {
                    ForEach(percentages, id: \.self) { percentage in
                        Text(String(
                            format: String(localized: "reading_progress_percent_label", defaultValue: "%d%%"),
                            percentage
                        ))
                        .font(.system(size: 9))
                        .foregroundStyle(secondaryTextColor)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/** Android-style 66-book repeat-read heatmap with compact, stable book tiles. */
private struct ReadingProgressBookHeatmap: View {
    /// Scripture-book summaries for one testament.
    let books: [ReadingProgressBookSummary]
    /// Shared dynamic scale maximum across both testaments.
    let effectiveMaximum: Double
    /// Selected Android KJVA book ordinal for chapter drill-down.
    @Binding var selectedBookOrdinal: Int?

    /// Android long-press command for the complete book's history.
    let onOpenHistory: (ReadingProgressBookSummary) -> Void

    /// Android `GridLayout` uses exactly six equal columns for both testaments.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    /** Builds tappable book cells whose intensity reflects total reads per chapter. */
    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(books) { summary in
                let argb = AndroidReadingProgressHeatmap.bookARGB(
                    readPercent: summary.readPercent,
                    effectiveMaximum: effectiveMaximum
                )
                HStack(spacing: 2) {
                    Text(summary.book.shortName)
                    if summary.isComplete {
                        Text("✓")
                            .font(.system(size: 7, weight: .bold))
                            .baselineOffset(4)
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(
                    summary.readPercent >= 1
                        ? Color.white
                        : AndroidReadingProgressColor.readingDarkText
                )
                .background(AndroidReadingProgressColor.readingColor(argb: argb))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(bookGesture(summary))
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(summary.book.longName)
                .accessibilityValue(String(format: "%.0f%%", summary.readPercent * 100))
                .accessibilityAction {
                    selectedBookOrdinal = summary.book.bibleBookOrdinal
                }
                .accessibilityAction(
                    named: String(
                        localized: "reading_progress_history_title",
                        defaultValue: "Read History"
                    )
                ) {
                    onOpenHistory(summary)
                }
            }
        }
    }

    /**
     Builds Android's mutually exclusive book tap/long-press gesture.

     - Parameter summary: Captured book cell.
     - Returns: An exclusive gesture that cannot drill down after opening history.
     - Side effects: a tap selects chapter detail; a long press opens book history.
     - Failure modes: a cancelled long press performs no action.
     */
    private func bookGesture(_ summary: ReadingProgressBookSummary) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first(true):
                    onOpenHistory(summary)
                case .second:
                    selectedBookOrdinal = summary.book.bibleBookOrdinal
                case .first(false):
                    break
                }
            }
    }
}

/** Android read-count legend for one selected book's chapter heatmap. */
private struct ReadingProgressChapterScale: View {
    /// Largest repeat-read count in the selected book.
    let maximumCount: Int

    /// Launching activity's `textColorSecondary` projection.
    let secondaryTextColor: Color

    /** Builds Android's one/five/effective-maximum anchored color scale. */
    var body: some View {
        let counts = AndroidReadingProgressHeatmap.chapterScaleCounts(maximumCount: maximumCount)
        HStack(alignment: .center, spacing: 6) {
            Text(String(localized: "reading_progress_read_count_scale", defaultValue: "Read\nCount"))
                .font(.system(size: 10))
                .foregroundStyle(secondaryTextColor)
                .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(counts, id: \.self) { count in
                        Rectangle()
                            .fill(AndroidReadingProgressColor.readingColor(
                                argb: AndroidReadingProgressHeatmap.chapterARGB(
                                    count: count,
                                    maximumCount: maximumCount
                                )
                            ))
                    }
                }
                .frame(height: 9)
                HStack(spacing: 0) {
                    ForEach(counts, id: \.self) { count in
                        Text("\(count)")
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryTextColor)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/** Android count-mode chapter heatmap for one selected KJV scripture book. */
private struct ReadingProgressChapterHeatmap: View {
    /// Selected Android KJVA book summary.
    let book: ReadingProgressBookSummary

    /// Launching activity's secondary text token for the count legend.
    let secondaryTextColor: Color
    /// Reader-owned navigation callback receiving KJVA OSIS ID and one-based chapter.
    let onOpenChapter: (String, Int) -> Void

    /// Android long-press command receiving the selected one-based chapter.
    let onOpenHistory: (Int) -> Void

    /// Android chooses five through ten equal columns from the selected book's chapter count.
    private var columns: [GridItem] {
        let columnCount = min(max(book.book.chapterCount, 5), 10)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount)
    }

    /** Builds fixed chapter cells whose intensity represents repeat-read count. */
    var body: some View {
        let maximum = max(book.chapterReadCounts.values.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            ReadingProgressChapterScale(
                maximumCount: maximum,
                secondaryTextColor: secondaryTextColor
            )
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(1...book.book.chapterCount, id: \.self) { chapter in
                    let count = book.chapterReadCounts[chapter, default: 0]
                    let argb = AndroidReadingProgressHeatmap.chapterARGB(
                        count: count,
                        maximumCount: maximum
                    )
                    Text("\(chapter)")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(minWidth: 36, maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(
                            AndroidReadingProgressHeatmap.usesLightForeground(argb: argb)
                                ? Color.white
                                : AndroidReadingProgressColor.readingDarkText
                        )
                        .background(AndroidReadingProgressColor.readingColor(argb: argb))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .gesture(chapterGesture(chapter))
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("\(book.book.longName) \(chapter)")
                        .accessibilityValue("\(count)")
                        .accessibilityAction {
                            onOpenChapter(book.book.osisId, chapter)
                        }
                        .accessibilityAction(
                            named: String(
                                localized: "reading_progress_history_title",
                                defaultValue: "Read History"
                            )
                        ) {
                            onOpenHistory(chapter)
                        }
                }
            }
        }
    }

    /** Builds Android's mutually exclusive chapter navigation/history gesture. */
    private func chapterGesture(_ chapter: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first(true):
                    onOpenHistory(chapter)
                case .second:
                    onOpenChapter(book.book.osisId, chapter)
                case .first(false):
                    break
                }
            }
    }
}

/** Android-equivalent 52-week local-day reading calendar. */
private struct ReadingProgressCalendarHeatmap: View {
    /// Android local-midnight activity buckets in the active cycle.
    let counts: [ReadingProgressDayCount]
    /// Android day-tap command that opens the shared Read History dialog.
    let onSelectDay: (Int64) -> Void

    private let calendar = Calendar.current
    private let cellSize: CGFloat = 14
    private let cellPadding: CGFloat = 2
    private let labelWidth: CGFloat = 24
    private let headerHeight: CGFloat = 16

    /** Builds Android's first-weekday-aligned 53-week calendar with non-empty-day selection. */
    var body: some View {
        let countsByDay = Dictionary(uniqueKeysWithValues: counts.map { ($0.dayStartMilliseconds, $0.count) })
        let maximum = max(counts.map(\.count).max() ?? 0, 1)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: cellPadding) {
                        Color.clear
                            .frame(width: labelWidth, height: headerHeight)
                        ForEach(0..<7, id: \.self) { dayIndex in
                            dayLabel(for: dayIndex)
                                .font(.system(size: 10))
                                .foregroundStyle(AndroidResourcePalette.gray)
                                .frame(width: labelWidth, height: cellSize, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                Text(monthLabel(forWeek: weekIndex))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AndroidResourcePalette.gray)
                                    .frame(width: cellSize, height: headerHeight, alignment: .leading)
                                    .lineLimit(1)
                            }
                        }

                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                VStack(spacing: cellPadding) {
                                    ForEach(0..<7, id: \.self) { dayIndex in
                                        if let day = calendarDay(weekIndex: weekIndex, dayIndex: dayIndex) {
                                            let milliseconds = dayStartMilliseconds(day)
                                            let count = countsByDay[milliseconds, default: 0]
                                            if count > 0 {
                                                Button {
                                                    onSelectDay(milliseconds)
                                                } label: {
                                                    calendarCell(
                                                        count: count,
                                                        maximum: maximum
                                                    )
                                                }
                                                .buttonStyle(.plain)
                                                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(count)")
                                                .accessibilityLabel(day.formatted(date: .long, time: .omitted))
                                                .accessibilityValue("\(count)")
                                            } else {
                                                calendarCell(count: 0, maximum: maximum)
                                                    .accessibilityLabel(day.formatted(date: .long, time: .omitted))
                                                    .accessibilityValue("0")
                                            }
                                        } else {
                                            Color.clear
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                                .id(weekIndex)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear {
                proxy.scrollTo(52, anchor: .trailing)
            }
        }
    }

    /// Local midnight at the first day of the week containing the date 52 weeks ago.
    private var calendarStart: Date {
        let today = calendar.startOfDay(for: Date())
        let shifted = calendar.date(byAdding: .weekOfYear, value: -52, to: today) ?? today
        return calendar.dateInterval(of: .weekOfYear, for: shifted)?.start ?? shifted
    }

    /** Resolves one visible calendar cell while omitting future dates. */
    private func calendarDay(weekIndex: Int, dayIndex: Int) -> Date? {
        guard let day = calendar.date(
            byAdding: .day,
            value: weekIndex * 7 + dayIndex,
            to: calendarStart
        ) else {
            return nil
        }
        return day <= calendar.startOfDay(for: Date()) ? day : nil
    }

    /** Builds one fixed-size Android activity cell. */
    private func calendarCell(count: Int, maximum: Int) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AndroidReadingProgressColor.memorizationCalendarColor(
                count: count,
                maxCount: maximum
            ))
            .frame(width: cellSize, height: cellSize)
    }

    /** Mirrors Android's sparse Monday/Wednesday/Friday row labels. */
    @ViewBuilder
    private func dayLabel(for dayIndex: Int) -> some View {
        switch dayIndex {
        case 1:
            Text("M")
        case 3:
            Text("W")
        case 5:
            Text("F")
        default:
            Text("")
        }
    }

    /** Emits a month abbreviation only when the first row crosses into a new month. */
    private func monthLabel(forWeek weekIndex: Int) -> String {
        guard let day = calendarDay(weekIndex: weekIndex, dayIndex: 0) else { return "" }
        if weekIndex > 0,
           let previous = calendarDay(weekIndex: weekIndex - 1, dayIndex: 0),
           calendar.component(.month, from: previous) == calendar.component(.month, from: day) {
            return ""
        }
        return day.formatted(.dateTime.month(.abbreviated))
    }

    /** Converts a local day to Android's local-midnight millisecond key. */
    private func dayStartMilliseconds(_ day: Date) -> Int64 {
        let start = calendar.startOfDay(for: day)
        return (try? AndroidTimestamp.milliseconds(from: start))
            ?? (start.timeIntervalSince1970.sign == .minus ? .min : .max)
    }
}
