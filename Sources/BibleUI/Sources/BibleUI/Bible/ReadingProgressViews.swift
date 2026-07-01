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
            return String(localized: "reading", defaultValue: "Reading")
        case .memorization:
            return String(localized: "memorization", defaultValue: "Memorization")
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
    let onOpenMemorizeRange: (MemorizationProgressRange) -> Void
    let onOpenChapter: (String, Int) -> Void
    @State private var selectedTab: ReadingProgressTab
    @AppStorage("reading_progress_mem_overview") private var memorizationOverviewActive = true
    @State private var memorizationRevision = 0
    @State private var memorizedPassagesShown = 10
    @State private var targetsShown = 10
    @State private var selectedMemorizationBookOsisId: String?
    @State private var memorizationDeletionRequest: MemorizationDeletionRequest?

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(
        readingStore: ReadingProgressStore?,
        memorizationStore: MemorizationProgressStore?,
        initialTab: ReadingProgressTab,
        onOpenMemorizeRange: @escaping (MemorizationProgressRange) -> Void = { _ in },
        onOpenChapter: @escaping (String, Int) -> Void = { _, _ in }
    ) {
        self.readingStore = readingStore
        self.memorizationStore = memorizationStore
        self.onOpenMemorizeRange = onOpenMemorizeRange
        self.onOpenChapter = onOpenChapter
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        Form {
            Picker(String(localized: "reading_progress", defaultValue: "Reading Progress"), selection: $selectedTab) {
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
        .navigationTitle(String(localized: "reading_progress", defaultValue: "Reading Progress"))
        .alert(item: $memorizationDeletionRequest) { request in
            Alert(
                title: Text(""),
                message: Text(request.message),
                primaryButton: .default(Text(String(localized: "ok", defaultValue: "OK"))) {
                    performMemorizationDeletion(request)
                    memorizationDeletionRequest = nil
                },
                secondaryButton: .cancel(Text(String(localized: "cancel", defaultValue: "Cancel")))
            )
        }
    }

    @ViewBuilder
    private var readingSection: some View {
        let summary = readingStore?.readingSummary() ?? ReadingProgressSummary(
            cycle: 1,
            distinctChapterCount: 0,
            readingCount: 0,
            recentRows: []
        )

        Section(String(localized: "summary", defaultValue: "Summary")) {
            LabeledContent(String(localized: "cycle", defaultValue: "Cycle"), value: "\(summary.cycle)")
            LabeledContent(String(localized: "chapters", defaultValue: "Chapters"), value: "\(summary.distinctChapterCount)")
            LabeledContent(String(localized: "readings", defaultValue: "Readings"), value: "\(summary.readingCount)")
        }

        Section(String(localized: "recent", defaultValue: "Recent")) {
            if summary.recentRows.isEmpty {
                Text(String(localized: "no_reading_history", defaultValue: "No reading history"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.recentRows, id: \.id) { row in
                    ReadingProgressHistoryRowView(row: row)
                }
            }
        }
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
        switch request.kind {
        case .memorizedPassage(let passage):
            _ = memorizationStore?.unmarkMemorized(
                bookInitials: "",
                startOrdinal: passage.range.startOrdinal,
                endOrdinal: passage.range.endOrdinal
            )
        case .target(let item):
            _ = memorizationStore?.removeMemorizationTarget(id: item.id)
        }
        memorizationRevision += 1
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
        Int64((calendar.startOfDay(for: day).timeIntervalSince1970 * 1000.0).rounded())
    }
}

private enum AndroidReadingProgressColor {
    static let targetDot = rgb(0x9C, 0x27, 0xB0)

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

struct ChapterReadHistoryView: View {
    let store: ReadingProgressStore?
    let target: ChapterReadHistoryTarget?

    var body: some View {
        Form {
            if let target {
                let rows = store?.chapterReadHistory(
                    kjvBookOrdinal: target.kjvBookOrdinal,
                    chapter: target.chapter
                ) ?? []
                Section("\(target.bookName) \(target.chapter)") {
                    if rows.isEmpty {
                        Text(String(localized: "no_reading_history", defaultValue: "No reading history"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(rows, id: \.id) { row in
                            ReadingProgressHistoryRowView(row: row)
                        }
                    }
                }
            } else {
                Text(String(localized: "no_reading_history", defaultValue: "No reading history"))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "reading_history", defaultValue: "Reading History"))
    }
}

private struct ReadingProgressHistoryRowView: View {
    let row: ReadingProgressHistoryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.bookInitials) \(row.chapter)")
                .font(.headline)
            HStack {
                Text(readAtText)
                Spacer()
                Text(row.source.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var readAtText: String {
        Date(timeIntervalSince1970: TimeInterval(row.readAt) / 1000.0)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
