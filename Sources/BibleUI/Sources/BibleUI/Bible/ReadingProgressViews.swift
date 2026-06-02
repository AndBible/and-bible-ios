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

struct ReadingProgressView: View {
    let readingStore: ReadingProgressStore?
    let memorizationStore: MemorizationProgressStore?
    @State private var selectedTab: ReadingProgressTab

    init(
        readingStore: ReadingProgressStore?,
        memorizationStore: MemorizationProgressStore?,
        initialTab: ReadingProgressTab
    ) {
        self.readingStore = readingStore
        self.memorizationStore = memorizationStore
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
        let memorizedCount = snapshot.memorizedRanges.reduce(0) { total, range in
            total + range.endOrdinal - range.startOrdinal + 1
        }
        let targetCount = snapshot.targetRanges.reduce(0) { total, range in
            total + range.endOrdinal - range.startOrdinal + 1
        }

        Section(String(localized: "summary", defaultValue: "Summary")) {
            LabeledContent(String(localized: "targets", defaultValue: "Targets"), value: "\(targetCount)")
            LabeledContent(String(localized: "memorized", defaultValue: "Memorized"), value: "\(memorizedCount)")
        }

        Section(String(localized: "settings", defaultValue: "Settings")) {
            let settings = readingStore?.snapshot().settings ?? ReadingProgressSettingsSnapshot()
            LabeledContent(
                String(localized: "word_visibility", defaultValue: "Word Visibility"),
                value: settings.memorizeWordVisibility.capitalized
            )
            LabeledContent(
                String(localized: "auto_mark_memorized", defaultValue: "Auto Mark Memorized"),
                value: settings.autoMarkMemorized ? String(localized: "on", defaultValue: "On") : String(localized: "off", defaultValue: "Off")
            )
        }
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
