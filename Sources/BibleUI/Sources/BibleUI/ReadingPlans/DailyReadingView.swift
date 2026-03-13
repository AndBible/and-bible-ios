// DailyReadingView.swift — Daily reading plan view

import SwiftUI
import SwiftData
import BibleCore

/**
 Shows one reading plan's current day, progress, and recent-day navigation.

 The view loads the selected plan from SwiftData, derives the expected current day, and lets the
 user mark days complete or incomplete while keeping the parent plan's active/completed state in sync.

 Data dependencies:
 - `planId` identifies the persisted reading plan to display
 - `modelContext` is used to load and persist plan/day progress changes

 Side effects:
 - `onAppear` loads the plan and derives the initial selected day index
 - marking or unmarking a day mutates SwiftData and may advance the selected day or reactivate the plan
 - plan completion status is recalculated after each completion change
 */
public struct DailyReadingView: View {
    /// Identifier of the reading plan to load and display.
    let planId: UUID

    /// SwiftData context used to load and persist plan progress.
    @Environment(\.modelContext) private var modelContext

    /// Loaded reading plan, or `nil` while the view is still hydrating.
    @State private var plan: ReadingPlan?

    /// Zero-based index of the currently selected day in `sortedDays`.
    @State private var currentDayIndex: Int = 0

    /// Reading plan days sorted by ascending day number.
    @State private var sortedDays: [ReadingPlanDay] = []

    /**
     Creates the daily reading screen for one persisted plan.

     - Parameter planId: Identifier of the plan whose day-by-day progress should be shown.
     */
    public init(planId: UUID) {
        self.planId = planId
    }

    /// Currently selected day, or `nil` when the plan has not loaded yet.
    private var currentDay: ReadingPlanDay? {
        guard currentDayIndex >= 0, currentDayIndex < sortedDays.count else { return nil }
        return sortedDays[currentDayIndex]
    }

    /// Completion percentage for the loaded plan in the range `0...1`.
    private var progress: Double {
        guard let plan else { return 0 }
        return ReadingPlanService.completionPercentage(for: plan)
    }

    /**
     Builds the loading state or the daily reading experience with progress and recent-day navigation.
     */
    public var body: some View {
        Group {
            if let plan, !sortedDays.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        planHeader(plan)
                        dayNavigator
                        if let day = currentDay {
                            readingCard(day)
                            recentDays
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("dailyReadingScreen")
            } else {
                ProgressView(String(localized: "daily_reading_loading"))
                    .accessibilityIdentifier("dailyReadingScreen")
            }
        }
        .navigationTitle(plan?.planName ?? String(localized: "daily_reading"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            loadPlan()
        }
    }

    /**
     Builds the plan summary header with start date and aggregate completion progress.
     */
    private func planHeader(_ plan: ReadingPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(plan.planName)
                        .font(.title2.weight(.bold))
                    Text("Started \(plan.startDate, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(progress >= 1.0 ? .green : .blue)
            }

            ProgressView(value: progress)
                .tint(progress >= 1.0 ? .green : .blue)

            let completedCount = sortedDays.filter(\.isCompleted).count
            Text("\(completedCount) of \(plan.totalDays) days completed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Previous/next day navigator for moving through the reading plan.
    private var dayNavigator: some View {
        HStack {
            Button {
                if currentDayIndex > 0 {
                    currentDayIndex -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .disabled(currentDayIndex <= 0)

            Spacer()

            Text("Day \(currentDayIndex + 1)")
                .font(.headline)
                .accessibilityIdentifier("dailyReadingCurrentDayLabel")
                .accessibilityValue("\(currentDayIndex + 1)")

            Spacer()

            Button {
                if currentDayIndex < sortedDays.count - 1 {
                    currentDayIndex += 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3)
            }
            .disabled(currentDayIndex >= sortedDays.count - 1)
        }
        .padding(.horizontal)
    }

    /**
     Builds the reading card for the currently selected day, including completion actions.
     */
    private func readingCard(_ day: ReadingPlanDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "daily_reading_today"))
                    .font(.headline)
                Spacer()
                if day.isCompleted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "completed"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            // Parse readings into individual passages
            let passages = day.readings.components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            ForEach(passages, id: \.self) { passage in
                HStack {
                    Image(systemName: "book")
                        .foregroundStyle(.blue)
                        .font(.body)
                    Text(passage)
                        .font(.body)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            if !day.isCompleted {
                Button {
                    markDayComplete(day)
                } label: {
                    HStack {
                        Spacer()
                        SwiftUI.Label(String(localized: "mark_as_read"), systemImage: "checkmark")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .accessibilityIdentifier("dailyReadingMarkAsReadButton")
            } else {
                Button {
                    unmarkDay(day)
                } label: {
                    HStack {
                        Spacer()
                        SwiftUI.Label(String(localized: "unmark"), systemImage: "arrow.uturn.backward")
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
                .accessibilityIdentifier("dailyReadingUnmarkButton")
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Compact list of nearby days for quick navigation around the current selection.
    private var recentDays: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "daily_reading_recent_days"))
                .font(.headline)
                .padding(.top, 8)

            let startIdx = max(0, currentDayIndex - 3)
            let endIdx = min(sortedDays.count, currentDayIndex + 4)
            let range = startIdx..<endIdx

            ForEach(range, id: \.self) { idx in
                let day = sortedDays[idx]
                HStack {
                    Text("Day \(idx + 1)")
                        .font(.subheadline.weight(idx == currentDayIndex ? .bold : .regular))
                        .frame(width: 60, alignment: .leading)

                    Text(day.readings)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if day.isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 2)
                .background(idx == currentDayIndex ? Color.blue.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onTapGesture {
                    currentDayIndex = idx
                }
            }
        }
    }

    /**
     Loads the selected plan from storage and derives the initial current-day selection.

     Side effects:
     - populates `plan` and `sortedDays`
     - derives the expected one-based current day from `ReadingPlanService` and converts it to a zero-based index
     */
    private func loadPlan() {
        let store = ReadingPlanStore(modelContext: modelContext)
        plan = store.plan(id: planId)

        if let plan {
            sortedDays = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
            // expectedDay returns 1-based day number; convert to 0-based index
            let expected = ReadingPlanService.expectedDay(for: plan) - 1
            currentDayIndex = min(max(expected, 0), max(sortedDays.count - 1, 0))
        }
    }

    /**
     Marks one day complete, saves progress, auto-advances when possible, and refreshes plan completion.

     - Parameter day: Day to mark completed.
     */
    private func markDayComplete(_ day: ReadingPlanDay) {
        day.isCompleted = true
        day.completedDate = Date()
        try? modelContext.save()

        // Auto-advance to next unread day
        if currentDayIndex < sortedDays.count - 1 {
            currentDayIndex += 1
        }

        // Check if plan is complete
        checkPlanCompletion()
    }

    /**
     Marks one day incomplete and reactivates the plan if it had previously completed.

     - Parameter day: Day to mark incomplete.
     */
    private func unmarkDay(_ day: ReadingPlanDay) {
        day.isCompleted = false
        day.completedDate = nil
        try? modelContext.save()

        // Reactivate plan if it was completed
        if let plan, !plan.isActive {
            plan.isActive = true
            try? modelContext.save()
        }
    }

    /**
     Updates the parent plan's `isActive` flag when every day is now complete.
     */
    private func checkPlanCompletion() {
        guard let plan else { return }
        let allDone = sortedDays.allSatisfy(\.isCompleted)
        if allDone {
            plan.isActive = false
            try? modelContext.save()
        }
    }
}
