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
 Native Reading Progress sheet for Android-aligned reading and memorization progress.

 The view reads immutable snapshots from the supplied progress stores on render, then mutates those
 stores only through explicit user actions such as removing memorized passages or target rows.
 Memorization rows open either the Android-style Memorize document range or the selected overview
 chapter through injected callbacks owned by the reader sheet.
 */
struct ReadingProgressView: View {
    let readingStore: ReadingProgressStore?
    let memorizationStore: MemorizationProgressStore?
    let settingsController: BibleReaderController?
    let onOpenMemorizeRange: (MemorizationProgressRange) -> Void
    let onOpenChapter: (String, Int) -> Void
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
    @State private var selectedReadingDayMilliseconds: Int64?
    @State private var showNewReadingCycleConfirmation = false
    @State private var persistenceFailure: ReadingProgressPersistenceFailure?
    @State private var isHelpPresented = false
    /// History rows staged for Android-style delete-on-dismiss with tap-again undo.
    @State private var pendingReadingDeleteIDs: Set<UUID> = []

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(
        readingStore: ReadingProgressStore?,
        memorizationStore: MemorizationProgressStore?,
        settingsController: BibleReaderController? = nil,
        initialTab: ReadingProgressTab? = nil,
        onOpenMemorizeRange: @escaping (MemorizationProgressRange) -> Void = { _ in },
        onOpenChapter: @escaping (String, Int) -> Void = { _, _ in }
    ) {
        self.readingStore = readingStore
        self.memorizationStore = memorizationStore
        self.settingsController = settingsController
        self.onOpenMemorizeRange = onOpenMemorizeRange
        self.onOpenChapter = onOpenChapter
        let persistedTab = ReadingProgressTab(
            rawValue: UserDefaults.standard.integer(forKey: "reading_progress_last_tab")
        ) ?? .reading
        _selectedTab = State(initialValue: initialTab ?? persistedTab)
    }

    var body: some View {
        Form {
            Picker(String(localized: "reading_progress_title", defaultValue: "Read/Memory Progress"), selection: $selectedTab) {
                ForEach(ReadingProgressTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .reading:
                readingSection
            case .memorization:
                memorizationSection
            }
        }
        .navigationTitle(String(localized: "reading_progress_title", defaultValue: "Read/Memory Progress"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let settingsController {
                    NavigationLink {
                        ReadingProgressSettingsView(controller: settingsController)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(String(localized: "settings", defaultValue: "Settings"))
                    .accessibilityIdentifier("readingProgressSettingsAction")
                }

                Button {
                    isHelpPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel(String(localized: "help", defaultValue: "Help"))
                .accessibilityIdentifier("readingProgressHelpAction")
            }
        }
        .onAppear {
            persistedTabRawValue = selectedTab.rawValue
        }
        .onChange(of: selectedTab) { _, tab in
            persistedTabRawValue = tab.rawValue
        }
        .overlay {
            if let request = memorizationDeletionRequest {
                ReadingProgressDecisionDialog(title: "", message: request.message, actions: [
                    .init(id: "confirm", title: String(localized: "ok", defaultValue: "OK")) { performMemorizationDeletion(request); memorizationDeletionRequest = nil },
                    .init(id: "cancel", title: String(localized: "cancel", defaultValue: "Cancel")) { memorizationDeletionRequest = nil }
                ])
            } else if persistenceFailure != nil {
                ReadingProgressDecisionDialog(title: String(localized: "reading_progress_save_failed", defaultValue: "Unable to save progress"), message: String(localized: "reading_progress_save_failed_message", defaultValue: "Your existing progress was left unchanged. Try again."), actions: [
                    .init(id: "okay", title: String(localized: "ok", defaultValue: "OK")) { persistenceFailure = nil }
                ])
            } else if isHelpPresented {
                ReadingProgressDecisionDialog(title: String(localized: "help", defaultValue: "Help"), message: String(localized: "help_reading_progress_text", defaultValue: "Your Bible reading and memorization progress at a glance. Mark chapters as read manually with the \"Mark as read\" button, or enable automatic tracking. Memorize exercises also feed into this view."), actions: [
                    .init(id: "okay", title: String(localized: "ok", defaultValue: "OK")) { isHelpPresented = false }
                ])
            } else if showNewReadingCycleConfirmation {
                ReadingProgressDecisionDialog(title: String(localized: "reading_progress_new_cycle", defaultValue: "New cycle"), message: String(localized: "reading_progress_new_cycle_confirm", defaultValue: "Start a new reading cycle? This will begin tracking your progress from scratch, while preserving your previous cycle's data."), actions: [
                    .init(id: "newCycle", title: String(localized: "reading_progress_new_cycle", defaultValue: "New cycle")) {
                        showNewReadingCycleConfirmation = false
                        guard applyPendingReadingDeletes() else { return }
                        do {
                            _ = try readingStore?.startNewCycle()
                            selectedReadingBookOrdinal = nil
                            selectedReadingDayMilliseconds = nil
                            readingRevision += 1
                        } catch { persistenceFailure = ReadingProgressPersistenceFailure() }
                    },
                    .init(id: "cancel", title: String(localized: "cancel", defaultValue: "Cancel")) { showNewReadingCycleConfirmation = false }
                ])
            }
        }
        .onDisappear {
            _ = applyPendingReadingDeletes()
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

        Group {
            Section {
                HStack {
                    Button {
                        selectReadingCycle(max(presentation.cycle - 1, 1))
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(presentation.cycle <= 1)
                    .help(String(localized: "reading_progress_previous_cycle", defaultValue: "Previous cycle"))

                    Spacer()
                    Text(String(
                        format: String(localized: "reading_progress_cycle", defaultValue: "Cycle %d"),
                        presentation.cycle
                    ))
                    .font(.headline)
                    Spacer()

                    Button {
                        selectReadingCycle(presentation.cycle + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(presentation.cycle >= presentation.latestCycle)
                    .help(String(localized: "reading_progress_next_cycle", defaultValue: "Next cycle"))

                    if presentation.cycle >= presentation.latestCycle {
                        Button {
                            showNewReadingCycleConfirmation = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(String(localized: "reading_progress_new_cycle", defaultValue: "New Cycle"))
                    }
                }
            }

            Section(String(localized: "summary", defaultValue: "Summary")) {
                LabeledContent(
                    String(localized: "reading_progress_chapters_read", defaultValue: "chapters read"),
                    value: "\(presentation.distinctChapterCount) / \(presentation.totalBibleChapterCount)"
                )
                LabeledContent(
                    String(localized: "reading_progress_active_days", defaultValue: "active days"),
                    value: "\(presentation.activeDayCount)"
                )
                ProgressView(value: presentation.overallProgress)
                Text(String(
                    format: String(localized: "reading_progress_overall", defaultValue: "%@%% of Bible read"),
                    String(format: "%.1f", presentation.overallPercent)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            readingBookSections(presentation)

            Section(String(localized: "reading_progress_calendar", defaultValue: "Reading activity")) {
                ReadingProgressCalendarHeatmap(
                    counts: presentation.calendar,
                    selectedDayMilliseconds: $selectedReadingDayMilliseconds
                )
            }

            readingHistorySection(presentation)
        }
        .id(readingRevision)
    }

    /** Renders Android's Old/New Testament book heatmaps and selected chapter counts. */
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
        Section(String(localized: "reading_progress_bible_heatmap", defaultValue: "Bible overview")) {
            ReadingProgressBookScale(effectiveMaximum: effectiveMaximum)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group.0)
                    .font(.subheadline.weight(.semibold))
                ReadingProgressBookHeatmap(
                    books: group.1,
                    effectiveMaximum: effectiveMaximum,
                    selectedBookOrdinal: $selectedReadingBookOrdinal
                )
            }

            if let selectedReadingBookOrdinal,
               let selectedBook = presentation.books.first(where: {
                   $0.book.bibleBookOrdinal == selectedReadingBookOrdinal
               }) {
                Divider()
                Text(selectedBook.book.longName)
                    .font(.headline)
                ReadingProgressChapterHeatmap(book: selectedBook, onOpenChapter: onOpenChapter)
            }
        }
    }

    /** Renders recent or selected Android history with one-row delete controls. */
    @ViewBuilder
    private func readingHistorySection(_ presentation: ReadingProgressPresentationSnapshot) -> some View {
        let rows = selectedReadingHistoryRows(in: presentation)
        Section(String(localized: "reading_progress_history_title", defaultValue: "Reading history")) {
            if rows.isEmpty {
                Text(String(
                    localized: "reading_progress_history_no_entries",
                    defaultValue: "No read entries for this selection."
                ))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows.prefix(50), id: \.id) { row in
                    let isPending = pendingReadingDeleteIDs.contains(row.id)
                    HStack {
                        ReadingProgressHistoryRowView(row: row)
                        Spacer()
                        Button {
                            if isPending {
                                pendingReadingDeleteIDs.remove(row.id)
                            } else {
                                pendingReadingDeleteIDs.insert(row.id)
                            }
                        } label: {
                            Image(systemName: isPending ? "arrow.uturn.backward" : "xmark")
                        }
                        .foregroundStyle(
                            isPending
                                ? AndroidReadingProgressColor.readingColor(
                                    argb: AndroidReadingProgressHeatmap.chapterMaximumARGB
                                )
                                : Color.secondary
                        )
                        .help(
                            isPending
                                ? String(localized: "undo", defaultValue: "Undo")
                                : String(localized: "delete", defaultValue: "Delete")
                        )
                    }
                    .opacity(isPending ? 0.45 : 1)
                }
            }
        }
    }

    /** Selects an existing Android reading cycle and clears drill-down filters. */
    private func selectReadingCycle(_ cycle: Int) {
        guard applyPendingReadingDeletes() else { return }
        do {
            _ = try readingStore?.setActiveCycle(cycle)
            selectedReadingBookOrdinal = nil
            selectedReadingDayMilliseconds = nil
            readingRevision += 1
        } catch {
            persistenceFailure = ReadingProgressPersistenceFailure()
        }
    }

    /** Commits Android-style pending history deletions when the history surface closes or changes cycle. */
    @discardableResult
    private func applyPendingReadingDeletes() -> Bool {
        guard !pendingReadingDeleteIDs.isEmpty else { return true }
        guard let readingStore else {
            pendingReadingDeleteIDs.removeAll()
            return true
        }
        for id in Array(pendingReadingDeleteIDs) {
            do {
                _ = try readingStore.deleteHistoryEntry(id: id)
                pendingReadingDeleteIDs.remove(id)
            } catch {
                persistenceFailure = ReadingProgressPersistenceFailure()
                readingRevision += 1
                return false
            }
        }
        readingRevision += 1
        return true
    }

    /** Resolves history for the selected day/book, otherwise Android's newest entries. */
    private func selectedReadingHistoryRows(
        in presentation: ReadingProgressPresentationSnapshot,
        calendar: Calendar = .current
    ) -> [ReadingProgressHistoryRow] {
        if let selectedReadingDayMilliseconds {
            let start = AndroidTimestamp.date(from: selectedReadingDayMilliseconds)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return presentation.recentRows.filter {
                let date = AndroidTimestamp.date(from: $0.readAt)
                return date >= start && date < end
            }
        }
        if let selectedReadingBookOrdinal {
            return presentation.recentRows.filter { $0.kjvBookOrdinal == selectedReadingBookOrdinal }
        }
        return Array(presentation.recentRows.prefix(20))
    }

    @ViewBuilder
    private var memorizationSection: some View {
        let snapshot = memorizationStore?.snapshot() ?? MemorizationProgressSnapshot()
        let presentation = MemorizationProgressPresentation(snapshot: snapshot)

        Group {
            Section {
                MemorizationSummaryView(summary: presentation.summary)
                if presentation.summary.targetTotal > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(
                            value: Double(presentation.summary.targetMemorized),
                            total: Double(presentation.summary.targetTotal)
                        )
                        Text(
                            targetProgressLabel(
                                memorized: presentation.summary.targetMemorized,
                                total: presentation.summary.targetTotal
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            Section {
                MemorizationViewToggle(overviewActive: $memorizationOverviewActive)
            }

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
        Section(String(localized: "memorize_memorized_passages", defaultValue: "Memorized passages")) {
            if presentation.memorizedPassages.isEmpty {
                Text(String(localized: "memorize_no_memorized_passages", defaultValue: "No memorized passages yet"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(presentation.memorizedPassages.prefix(memorizedPassagesShown))) { passage in
                    memorizedPassageRow(passage)
                }
                if presentation.memorizedPassages.count > memorizedPassagesShown {
                    Button(showMoreTitle(remaining: presentation.memorizedPassages.count - memorizedPassagesShown)) {
                        memorizedPassagesShown += 10
                    }
                }
            }
        }

        Section(String(localized: "memorize_targets", defaultValue: "Memorization goals")) {
            if presentation.incompleteTargets.isEmpty {
                Text(String(localized: "memorize_no_targets", defaultValue: "No memorization goals set"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(presentation.incompleteTargets.prefix(targetsShown))) { item in
                    memorizationTargetRow(item)
                }
                if presentation.incompleteTargets.count > targetsShown {
                    Button(showMoreTitle(remaining: presentation.incompleteTargets.count - targetsShown)) {
                        targetsShown += 10
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func memorizationOverviewSections(_ presentation: MemorizationProgressPresentation) -> some View {
        let oldTestamentBooks = presentation.books.filter { !$0.isNewTestament }
        let newTestamentBooks = presentation.books.filter(\.isNewTestament)

        Section(String(localized: "old_testament", defaultValue: "Old Testament")) {
            MemorizationBookGridView(
                books: oldTestamentBooks,
                selectedOsisId: selectedMemorizationBookOsisId
            ) { osisId in
                selectedMemorizationBookOsisId = osisId
            }
        }

        Section(String(localized: "new_testament", defaultValue: "New Testament")) {
            MemorizationBookGridView(
                books: newTestamentBooks,
                selectedOsisId: selectedMemorizationBookOsisId
            ) { osisId in
                selectedMemorizationBookOsisId = osisId
            }
        }

        if let selectedMemorizationBookOsisId,
           let detail = presentation.chapterDetail(osisId: selectedMemorizationBookOsisId) {
            Section(detail.title) {
                MemorizationChapterGridView(detail: detail, onOpenChapter: onOpenChapter)
            }
        }

        Section(String(localized: "memorize_calendar", defaultValue: "Memorization Activity")) {
            MemorizationCalendarView(counts: presentation.calendarCountsByDayStartMilliseconds)
        }
    }

    private func memorizedPassageRow(
        _ passage: MemorizationProgressPresentation.MemorizedPassage
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(passage.title)
                    .font(.body)
                Text(relativeDateText(milliseconds: passage.latestMemorizedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                memorizationDeletionRequest = MemorizationDeletionRequest(
                    message: removeMemorizedPassageConfirmationTitle(passage.title),
                    kind: .memorizedPassage(passage)
                )
            } label: {
                Image(systemName: "xmark.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "remove", defaultValue: "Remove"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenMemorizeRange(passage.range)
        }
    }

    private func memorizationTargetRow(
        _ item: MemorizationProgressPresentation.TargetItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.title) (\(item.memorizedCount)/\(item.verseCount))")
                        .font(.body)
                    Text(relativeDateText(milliseconds: item.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    memorizationDeletionRequest = MemorizationDeletionRequest(
                        message: removeMemorizationTargetConfirmationTitle(item.title),
                        kind: .target(item)
                    )
                } label: {
                    Image(systemName: "xmark.circle")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "remove", defaultValue: "Remove"))
            }
            ProgressView(value: item.progressFraction)
        }
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

private struct MemorizationSummaryView: View {
    let summary: MemorizationProgressPresentation.Summary

    var body: some View {
        HStack(spacing: 0) {
            summaryColumn(
                value: "\(summary.totalMemorized)",
                label: String(localized: "memorize_verses_memorized", defaultValue: "Memorized")
            )
            summaryColumn(
                value: summary.targetTotal > 0 ? "\(summary.targetTotal)" : "-",
                label: String(localized: "memorize_verses_target", defaultValue: "Goal")
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

    var body: some View {
        HStack(spacing: 0) {
            Button(String(localized: "memorize_view_overview", defaultValue: "Overview")) {
                overviewActive = true
            }
            .font(.system(size: 17, weight: overviewActive ? .bold : .regular))
            .frame(maxWidth: .infinity)

            Button(String(localized: "memorize_view_list", defaultValue: "List")) {
                overviewActive = false
            }
            .font(.system(size: 17, weight: overviewActive ? .regular : .bold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
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
    let selectedOsisId: String?
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                selectedOsisId == book.osisId ? Color.accentColor : Color.clear,
                                lineWidth: 2
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(book.title)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MemorizationChapterGridView: View {
    let detail: MemorizationProgressPresentation.ChapterDetail
    let onOpenChapter: (String, Int) -> Void

    private var columns: [GridItem] {
        let columnCount = min(max(detail.chapters.count, 5), 10)
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
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
        .padding(.vertical, 4)
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
                                .frame(width: labelWidth, height: cellSize, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                Text(monthLabel(forWeek: weekIndex))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
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

/**
 Native settings form for reading and memorization progress behavior.

 The view edits the focused reader controller's progress settings when a controller is available
 and otherwise renders default values for routes opened before a pane controller is ready.

 - Parameters:
   - controller: Optional reader controller that owns the progress stores to mutate.
 - Side effects: User edits call `saveReadingProgressSettings(_:)` on the supplied controller.
 - Failure modes: Missing controllers keep edits local to the view state.
 */
struct ReadingProgressSettingsView: View {
    let controller: BibleReaderController?
    @State private var settings: ReadingProgressSettingsSnapshot

    init(controller: BibleReaderController?) {
        self.controller = controller
        _settings = State(initialValue: controller?.readingProgressStore?.snapshot().settings ?? ReadingProgressSettingsSnapshot())
    }

    var body: some View {
        Form {
            Section(String(localized: "reading", defaultValue: "Reading")) {
                Toggle(String(localized: "auto_track_reading", defaultValue: "Auto Track Reading"), isOn: settingBinding(\.autoTrackReading))
            }

            Section(String(localized: "memorization", defaultValue: "Memorization")) {
                Toggle(String(localized: "auto_mark_memorized", defaultValue: "Auto Mark Memorized"), isOn: settingBinding(\.autoMarkMemorized))
                Toggle(String(localized: "full_words", defaultValue: "Full Words"), isOn: settingBinding(\.memorizeTypeFullWords))
                Toggle(String(localized: "error_heatmap", defaultValue: "Error Heatmap"), isOn: settingBinding(\.memorizeErrorHeatmap))
                Toggle(String(localized: "hide_used_words", defaultValue: "Hide Used Words"), isOn: settingBinding(\.memorizeScrambleHideUsed))
                Toggle(String(localized: "include_reference", defaultValue: "Include Reference"), isOn: settingBinding(\.memorizeIncludeReference))

                Picker(
                    String(localized: "word_visibility", defaultValue: "Word Visibility"),
                    selection: settingBinding(\.memorizeWordVisibility)
                ) {
                    Text(String(localized: "light", defaultValue: "Light")).tag("light")
                    Text(String(localized: "dim", defaultValue: "Dim")).tag("dim")
                    Text(String(localized: "hidden", defaultValue: "Hidden")).tag("hidden")
                }
            }
        }
        .navigationTitle(String(localized: "reading_progress_settings", defaultValue: "Reading Progress Settings"))
        .accessibilityIdentifier("readingProgressSettingsScreen")
    }

    /**
     Creates a binding that persists one reading-progress setting after each edit.

     - Parameter keyPath: Writable key path for the setting value inside the local snapshot.
     - Returns: A SwiftUI binding suitable for toggles and pickers.
     - Side Effects: Mutates local state and saves through the optional reader controller.
     - Failure: When the controller is absent or saving fails, the local edited value remains until
       the view is recreated.
     */
    private func settingBinding<Value>(_ keyPath: WritableKeyPath<ReadingProgressSettingsSnapshot, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                settings[keyPath: keyPath] = value
                if let savedSettings = controller?.saveReadingProgressSettings(settings) {
                    settings = savedSettings
                }
            }
        )
    }
}

/** Android percentage legend for the repeat-read book heatmap. */
private struct ReadingProgressBookScale: View {
    /// Dynamic Android scale maximum, where `1` represents 100 percent.
    let effectiveMaximum: Double

    /** Builds Android's fixed 25-percent color bands through the effective maximum. */
    var body: some View {
        let percentages = AndroidReadingProgressHeatmap.bookScalePercentages(
            maximumReadPercent: effectiveMaximum
        )
        HStack(alignment: .center, spacing: 6) {
            Text(String(localized: "reading_progress_percent_read_scale", defaultValue: "Percent\nRead"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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

    private let columns = [GridItem(.adaptive(minimum: 48, maximum: 64), spacing: 6)]

    /** Builds tappable book cells whose intensity reflects total reads per chapter. */
    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(books) { summary in
                let argb = AndroidReadingProgressHeatmap.bookARGB(
                    readPercent: summary.readPercent,
                    effectiveMaximum: effectiveMaximum
                )
                Button {
                    selectedBookOrdinal = summary.book.bibleBookOrdinal
                } label: {
                    HStack(spacing: 2) {
                        Text(summary.book.shortName)
                        if summary.isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .alignmentGuide(.firstTextBaseline) { dimensions in
                                    dimensions[.bottom]
                                }
                        }
                    }
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(
                            summary.readPercent >= 1
                                ? Color.white
                                : AndroidReadingProgressColor.readingDarkText
                        )
                        .background(AndroidReadingProgressColor.readingColor(argb: argb))
                        .overlay {
                            if selectedBookOrdinal == summary.book.bibleBookOrdinal {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.primary, lineWidth: 2)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary.book.longName)
                .accessibilityValue(String(format: "%.0f%%", summary.readPercent * 100))
            }
        }
    }
}

/** Android read-count legend for one selected book's chapter heatmap. */
private struct ReadingProgressChapterScale: View {
    /// Largest repeat-read count in the selected book.
    let maximumCount: Int

    /** Builds Android's one/five/effective-maximum anchored color scale. */
    var body: some View {
        let counts = AndroidReadingProgressHeatmap.chapterScaleCounts(maximumCount: maximumCount)
        HStack(alignment: .center, spacing: 6) {
            Text(String(localized: "reading_progress_read_count_scale", defaultValue: "Read\nCount"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
    /// Reader-owned navigation callback receiving KJVA OSIS ID and one-based chapter.
    let onOpenChapter: (String, Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 32, maximum: 42), spacing: 5)]

    /** Builds fixed chapter cells whose intensity represents repeat-read count. */
    var body: some View {
        let maximum = max(book.chapterReadCounts.values.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            ReadingProgressChapterScale(maximumCount: maximum)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(1...book.book.chapterCount, id: \.self) { chapter in
                    let count = book.chapterReadCounts[chapter, default: 0]
                    let argb = AndroidReadingProgressHeatmap.chapterARGB(
                        count: count,
                        maximumCount: maximum
                    )
                    Button {
                        onOpenChapter(book.book.osisId, chapter)
                    } label: {
                        Text("\(chapter)")
                            .font(.caption2.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(
                                AndroidReadingProgressHeatmap.usesLightForeground(argb: argb)
                                    ? Color.white
                                    : AndroidReadingProgressColor.readingDarkText
                            )
                            .background(AndroidReadingProgressColor.readingColor(argb: argb))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(book.book.longName) \(chapter)")
                    .accessibilityValue("\(count)")
                }
            }
        }
    }
}

/** Android-equivalent 52-week local-day reading calendar. */
private struct ReadingProgressCalendarHeatmap: View {
    /// Android local-midnight activity buckets in the active cycle.
    let counts: [ReadingProgressDayCount]
    /// Selected non-empty local day used to filter history rows.
    @Binding var selectedDayMilliseconds: Int64?

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
                                .frame(width: labelWidth, height: cellSize, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: cellPadding) {
                            ForEach(0..<53, id: \.self) { weekIndex in
                                Text(monthLabel(forWeek: weekIndex))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
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
                                                    selectedDayMilliseconds = milliseconds
                                                } label: {
                                                    calendarCell(
                                                        count: count,
                                                        maximum: maximum,
                                                        selected: selectedDayMilliseconds == milliseconds
                                                    )
                                                }
                                                .buttonStyle(.plain)
                                                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(count)")
                                                .accessibilityLabel(day.formatted(date: .long, time: .omitted))
                                                .accessibilityValue("\(count)")
                                            } else {
                                                calendarCell(count: 0, maximum: maximum, selected: false)
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
    private func calendarCell(count: Int, maximum: Int, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AndroidReadingProgressColor.memorizationCalendarColor(
                count: count,
                maxCount: maximum
            ))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.primary, lineWidth: 1.5)
                }
            }
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

struct ChapterReadHistoryView: View {
    let store: ReadingProgressStore?
    let target: ChapterReadHistoryTarget?
    @State private var revision = 0
    /// Rows staged for deletion and committed when this Android-equivalent history surface closes.
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var persistenceFailure: ReadingProgressPersistenceFailure?

    var body: some View {
        Form {
            if let target {
                let _ = revision
                let rows = store?.chapterReadHistory(
                    kjvBookOrdinal: target.kjvBookOrdinal,
                    chapter: target.chapter
                ) ?? []
                Section(chapterSubject(for: target)) {
                    if rows.isEmpty {
                        Text(String(
                            localized: "reading_progress_history_no_entries",
                            defaultValue: "No read entries for this selection."
                        ))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows, id: \.id) { row in
                            let isPending = pendingDeleteIDs.contains(row.id)
                            HStack {
                                ReadingProgressHistoryRowView(row: row, showsChapterReference: false)
                                Spacer()
                                Button {
                                    if isPending {
                                        pendingDeleteIDs.remove(row.id)
                                    } else {
                                        pendingDeleteIDs.insert(row.id)
                                    }
                                } label: {
                                    Image(systemName: isPending ? "arrow.uturn.backward" : "xmark")
                                }
                                .foregroundStyle(
                                    isPending
                                        ? AndroidReadingProgressColor.readingColor(
                                            argb: AndroidReadingProgressHeatmap.chapterMaximumARGB
                                        )
                                        : Color.secondary
                                )
                                .help(
                                    isPending
                                        ? String(localized: "undo", defaultValue: "Undo")
                                        : String(localized: "delete", defaultValue: "Delete")
                                )
                            }
                            .opacity(isPending ? 0.45 : 1)
                        }
                    }
                }
            } else {
                Text(String(
                    localized: "reading_progress_history_no_entries",
                    defaultValue: "No read entries for this selection."
                ))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "reading_progress_history_title", defaultValue: "Read History"))
        .overlay {
            if persistenceFailure != nil {
                ReadingProgressDecisionDialog(
                    title: String(localized: "reading_progress_save_failed", defaultValue: "Unable to save progress"),
                    message: String(localized: "reading_progress_save_failed_message", defaultValue: "Your existing progress was left unchanged. Try again."),
                    actions: [.init(id: "okay", title: String(localized: "ok", defaultValue: "OK")) { persistenceFailure = nil }]
                )
            }
        }
        .onDisappear {
            _ = applyPendingDeletes()
        }
    }

    /** Commits rows still staged when the fixed-chapter history surface closes. */
    @discardableResult
    private func applyPendingDeletes() -> Bool {
        guard !pendingDeleteIDs.isEmpty else { return true }
        guard let store else {
            pendingDeleteIDs.removeAll()
            return true
        }
        for id in Array(pendingDeleteIDs) {
            do {
                _ = try store.deleteHistoryEntry(id: id)
                pendingDeleteIDs.remove(id)
            } catch {
                persistenceFailure = ReadingProgressPersistenceFailure()
                revision += 1
                return false
            }
        }
        revision += 1
        return true
    }

    /** Resolves Android's short KJVA subject for the fixed-chapter history view. */
    private func chapterSubject(for target: ChapterReadHistoryTarget) -> String {
        let shortName = ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: target.kjvBookOrdinal,
            chapter: target.chapter
        )?.book.shortName ?? target.bookName
        return String(
            format: String(
                localized: "reading_progress_history_for",
                defaultValue: "Reading progress for %@"
            ),
            "\(shortName) \(target.chapter)"
        )
    }
}

/** Android read-history row with KJVA reference, timestamp, and source-version fallback. */
private struct ReadingProgressHistoryRowView: View {
    /// Persisted Android chapter-history row.
    let row: ReadingProgressHistoryRow
    /// Whether the containing history selection spans more than one chapter.
    let showsChapterReference: Bool

    /** Creates either Android's chapter-per-row or fixed-chapter history presentation. */
    init(row: ReadingProgressHistoryRow, showsChapterReference: Bool = true) {
        self.row = row
        self.showsChapterReference = showsChapterReference
    }

    /** Renders the same primary/secondary text split as Android `ReadHistoryDialog`. */
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryText)
                .font(.headline)
            Text(secondaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Android primary row content for a broad or fixed-chapter selection.
    private var primaryText: String {
        if showsChapterReference {
            return "\(row.androidDisplayReference) · \(timeText)"
        }
        return "\(dateText) \(timeText)"
    }

    /// Android secondary row content for a broad or fixed-chapter selection.
    private var secondaryText: String {
        showsChapterReference ? "\(dateText) · \(versionText)" : versionText
    }

    /// Localized date text matching Android's device date formatter.
    private var dateText: String {
        readDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// Localized time text matching Android's device time formatter.
    private var timeText: String {
        readDate.formatted(date: .omitted, time: .shortened)
    }

    /// Stored source module initials or Android's localized unknown-version fallback.
    private var versionText: String {
        row.androidDisplayVersion ?? String(
            localized: "reading_progress_history_version_unknown",
            defaultValue: "Unknown version"
        )
    }

    /// Persisted epoch milliseconds converted once for row formatting.
    private var readDate: Date {
        AndroidTimestamp.date(from: row.readAt)
    }
}
