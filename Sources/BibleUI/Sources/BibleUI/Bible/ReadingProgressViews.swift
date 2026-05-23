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
            Picker(String(localized: "reading_progress"), selection: $selectedTab) {
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
        let snapshot = readingStore?.snapshot() ?? ReadingProgressSnapshot()
        let cycle = readingStore?.currentCycle() ?? 1
        let activeRows = snapshot.history.filter { $0.cycle == cycle }
        let distinctChapters = Set(activeRows.map { "\($0.kjvBookOrdinal):\($0.chapter)" }).count

        Section(String(localized: "summary", defaultValue: "Summary")) {
            LabeledContent(String(localized: "cycle", defaultValue: "Cycle"), value: "\(cycle)")
            LabeledContent(String(localized: "chapters", defaultValue: "Chapters"), value: "\(distinctChapters)")
            LabeledContent(String(localized: "readings", defaultValue: "Readings"), value: "\(activeRows.count)")
        }

        Section(String(localized: "recent", defaultValue: "Recent")) {
            let recentRows = activeRows.sorted {
                if $0.readAt != $1.readAt {
                    return $0.readAt > $1.readAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(20)
            if recentRows.isEmpty {
                Text(String(localized: "no_reading_history", defaultValue: "No reading history"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(recentRows), id: \.id) { row in
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
    }

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
