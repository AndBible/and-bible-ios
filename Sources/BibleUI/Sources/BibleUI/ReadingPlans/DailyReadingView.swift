// DailyReadingView.swift — Daily reading plan view

import SwiftUI
import SwiftData
import BibleCore

/**
 Shows one reading plan's current day, progress, exact reader actions, and recent-day navigation.

 The view loads the selected plan from SwiftData, derives Android's current day, and persists each
 reading's completion independently in Android's `ReadingPlanStatus` JSON contract.

 Data dependencies:
 - `planId` identifies the persisted reading plan to display
 - `modelContext` is used to load and persist plan/day progress changes
 - `planVersificationResolver` supplies the definition's optional raw JSword versification and
   throws when the definition itself cannot be loaded
 - `onPerformAction` maps exact plan-canon targets into the active module and performs Read/Speak

 Side effects:
 - `onAppear` loads the plan and derives the initial selected day index
 - toggling a reading updates its Android status row and the derived SwiftData day cache
 - toolbar actions can rebase the start date, set the selected day as current, or reset the plan
 - successful Read, Speak, and Speak All callbacks mark only their represented reading numbers
 - dismissal cancels in-flight action work before it can mutate progress
 - plan completion status is recalculated after each completion change
 */
public struct DailyReadingView: View {
    /// Identifier of the reading plan to load and display.
    let planId: UUID

    /// Loads the optional raw JSword versification declared by one plan definition.
    let planVersificationResolver: ReadingPlanVersificationResolver?

    /// Parent-owned active-module mapper and Read/Speak action handler.
    let onPerformAction: DailyReadingActionHandler?

    /// Parent-owned route closure invoked after a successful Read has saved progress.
    let onReadCompleted: (@MainActor () -> Void)?

    /// SwiftData context used to load and persist plan progress.
    @Environment(\.modelContext) private var modelContext

    /// Dismiss action used after resetting the current plan graph.
    @Environment(\.dismiss) private var dismiss

    /// Loaded reading plan, or `nil` while the view is still hydrating.
    @State private var plan: ReadingPlan?

    /// Zero-based index of the currently selected day in `sortedDays`.
    @State private var currentDayIndex: Int = 0

    /// Reading plan days sorted by ascending day number.
    @State private var sortedDays: [ReadingPlanDay] = []

    /// Whether the start-date picker sheet is currently presented.
    @State private var showStartDatePicker = false

    /// Draft start date edited in the start-date picker before it is saved.
    @State private var draftStartDate = Date()

    /// Whether the destructive reset confirmation is currently presented.
    @State private var showResetConfirmation = false

    /// Forces status-backed rows to refresh after best-effort settings writes.
    @State private var statusRevision = 0

    /// One replaceable Read/Speak operation owned by this presentation.
    @State private var actionTask: Task<Void, Never>?

    /// Identity of the operation currently represented by progress UI.
    @State private var activeAction: DailyReadingPendingAction?

    /// Generation allowed to clear state or dismiss after the parent action returns.
    @State private var actionGeneration = UUID()

    /// Visible request-construction or parent-action failure.
    @State private var actionFailureMessage: String?

    /**
     Creates the daily reading screen for one persisted plan.

     - Parameters:
       - planId: Identifier of the plan whose day-by-day progress should be shown.
       - planVersificationResolver: Loads the plan definition's optional raw versification value,
         throwing when the definition itself is unavailable.
       - onPerformAction: Maps and validates targets in the active Bible, then navigates or starts speech.
       - onReadCompleted: Closes the parent reading-plan route after Read progress is durable.
     - Side effects: None until the user requests an action.
     - Failure modes: Missing callbacks fail visibly and never mark progress.
     */
    public init(
        planId: UUID,
        planVersificationResolver: ReadingPlanVersificationResolver? = nil,
        onPerformAction: DailyReadingActionHandler? = nil,
        onReadCompleted: (@MainActor () -> Void)? = nil
    ) {
        self.planId = planId
        self.planVersificationResolver = planVersificationResolver
        self.onPerformAction = onPerformAction
        self.onReadCompleted = onReadCompleted
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

    /// Android per-reading status store bound to this view's persistence context.
    private var progressStore: ReadingPlanProgressStore {
        ReadingPlanProgressStore(
            modelContext: modelContext,
            settingsStore: SettingsStore(modelContext: modelContext)
        )
    }

    /// Android single-selected-plan preference store bound to this view's persistence context.
    private var selectionStore: ReadingPlanSelectionStore {
        ReadingPlanSelectionStore(settingsStore: SettingsStore(modelContext: modelContext))
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                dailyReadingActionsMenu
            }
        }
        .sheet(isPresented: $showStartDatePicker) {
            startDatePickerSheet
        }
        .confirmationDialog(
            String(localized: "reading_plan_reset_title", defaultValue: "Reset Reading Plan?"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "reset", defaultValue: "Reset"), role: .destructive) {
                resetCurrentPlan()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "reading_plan_reset_message",
                defaultValue: "This removes the plan and its reading progress."
            ))
        }
        .alert(
            String(localized: "error_occurred", defaultValue: "Error"),
            isPresented: Binding(
                get: { actionFailureMessage != nil },
                set: { if !$0 { actionFailureMessage = nil } }
            )
        ) {
            Button(String(localized: "ok", defaultValue: "OK"), role: .cancel) {
                actionFailureMessage = nil
            }
        } message: {
            Text(actionFailureMessage ?? "")
        }
        .onAppear {
            loadPlan()
        }
        .onDisappear(perform: cancelReadingAction)
    }

    /// Android-parity current-plan actions exposed from the daily-reading toolbar.
    private var dailyReadingActionsMenu: some View {
        Menu {
            if let plan, !ReadingPlanService.isDateBased(plan) {
                Button {
                    setSelectedDayAsCurrent()
                } label: {
                    SwiftUI.Label(
                        String(localized: "reading_plan_set_current_day", defaultValue: "Set Current Day"),
                        systemImage: "calendar.badge.clock"
                    )
                }
                .disabled(currentDay == nil)
                .accessibilityIdentifier("dailyReadingSetCurrentDayButton")

                Button {
                    presentStartDatePicker()
                } label: {
                    SwiftUI.Label(
                        String(localized: "reading_plan_set_start_date", defaultValue: "Set Start Date"),
                        systemImage: "calendar"
                    )
                }
                .accessibilityIdentifier("dailyReadingSetStartDateButton")
            }

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                SwiftUI.Label(
                    String(localized: "reading_plan_reset", defaultValue: "Reset"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .disabled(plan == nil)
            .accessibilityIdentifier("dailyReadingResetPlanButton")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("dailyReadingActionsMenuButton")
    }

    /// Modal date picker for Android's set-start-date action.
    private var startDatePickerSheet: some View {
        NavigationStack {
            Form {
                DatePicker(
                    String(localized: "reading_plan_start_date", defaultValue: "Start Date"),
                    selection: $draftStartDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .accessibilityIdentifier("dailyReadingStartDatePicker")
            }
            .navigationTitle(String(localized: "reading_plan_set_start_date", defaultValue: "Set Start Date"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        showStartDatePicker = false
                    }
                    .accessibilityIdentifier("dailyReadingStartDateCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) {
                        applyDraftStartDate()
                    }
                    .accessibilityIdentifier("dailyReadingStartDateDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
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
                    if !ReadingPlanService.isDateBased(plan) {
                        Text("Started \(plan.startDate, style: .date)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            let displayedDayNumber = currentDay?.dayNumber
                ?? plan.map { ReadingPlanService.expectedDay(for: $0) }
                ?? 1
            Text("Day \(displayedDayNumber)")
                .font(.headline)
                .accessibilityIdentifier("dailyReadingCurrentDayLabel")
                .accessibilityValue("\(displayedDayNumber)")

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
        let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
        let dayStatus = status(for: day)
        let allRead = dayStatus.isAllRead(readingCount: assignment.readings.count)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "daily_reading_today"))
                    .font(.headline)
                Spacer()
                if allRead {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "completed"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            ForEach(Array(assignment.readings.enumerated()), id: \.offset) { offset, passage in
                let readingNumber = offset + 1
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { self.status(for: day).isRead(readingNumber) },
                        set: { setReading(readingNumber, isRead: $0, day: day) }
                    )) {
                        Text(passage)
                            .font(.body)
                    }
                    .toggleStyle(ReadingPlanCheckboxToggleStyle())
                    .disabled(!isReadingEditable(day))
                    .accessibilityIdentifier("dailyReadingStatusToggle::\(readingNumber)")

                    HStack(spacing: 8) {
                        Spacer()
                        dailyReadingActionButton(
                            kind: .read,
                            readingNumbers: [readingNumber],
                            assignment: assignment,
                            day: day
                        )
                        dailyReadingActionButton(
                            kind: .speak,
                            readingNumbers: [readingNumber],
                            assignment: assignment,
                            day: day
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            if assignment.readings.count > 1 {
                Divider()
                HStack {
                    Text(String(localized: "all", defaultValue: "All"))
                        .font(.body.weight(.medium))
                    Spacer()
                    dailyReadingActionButton(
                        kind: .speak,
                        readingNumbers: Array(1...assignment.readings.count),
                        assignment: assignment,
                        day: day,
                        speaksAll: true
                    )
                }
            }

            Button {
                finishDay(day)
            } label: {
                HStack {
                    Spacer()
                    SwiftUI.Label(String(localized: "done"), systemImage: "checkmark")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!allRead)
            .padding(.top, 4)
            .accessibilityIdentifier("dailyReadingDoneButton")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /**
     Builds one Read, Speak, or Speak All command with stable in-flight feedback.

     - Parameters:
       - kind: Reader operation represented by the button.
       - readingNumbers: One-based assignment positions represented by the operation.
       - assignment: Parsed day assignment used to build exact source-canon targets.
       - day: Persisted day whose progress may be marked after success.
       - speaksAll: Whether the speech button represents every reading.
     - Returns: Bordered command button that cannot start overlapping work.
     - Side effects: Tapping starts `performReadingAction`.
     - Failure modes: Failures are presented by the owning view alert.
     */
    private func dailyReadingActionButton(
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        assignment: ReadingPlanDayAssignment,
        day: ReadingPlanDay,
        speaksAll: Bool = false
    ) -> some View {
        let pending = DailyReadingPendingAction(kind: kind, readingNumbers: readingNumbers)
        let isRunning = activeAction == pending
        let title: String
        let icon: String
        switch (kind, speaksAll) {
        case (.read, _):
            title = String(localized: "read", defaultValue: "Read")
            icon = "book"
        case (.speak, true):
            title = String(localized: "speak", defaultValue: "Speak")
            icon = "speaker.wave.2"
        case (.speak, false):
            title = String(localized: "speak", defaultValue: "Speak")
            icon = "speaker.wave.2"
        }

        return Button {
            performReadingAction(
                kind: kind,
                readingNumbers: readingNumbers,
                assignment: assignment,
                day: day
            )
        } label: {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(title)
            } else {
                SwiftUI.Label(title, systemImage: icon)
            }
        }
        .buttonStyle(.bordered)
        .disabled(actionTask != nil)
        .accessibilityIdentifier(
            "dailyReading\(kind == .read ? "Read" : (speaksAll ? "SpeakAll" : "Speak"))Button::\(readingNumbers.map(String.init).joined(separator: "-"))"
        )
    }

    /**
     Builds and executes one exact plan-canon action before marking represented readings complete.

     - Parameters:
       - kind: Read or speech operation.
       - readingNumbers: One-based reading positions to parse and mark after success.
       - assignment: Current day's canonical Android assignment.
       - day: Persisted day receiving successful progress updates.
     - Side effects: Invokes the parent handler, marks progress after success, and dismisses after Read.
     - Failure modes: Missing wiring, invalid plan references, unsupported versification, mapping
       failures, and speech/navigation failures show an alert and do not mutate progress.
     */
    private func performReadingAction(
        kind: DailyReadingActionKind,
        readingNumbers: [Int],
        assignment: ReadingPlanDayAssignment,
        day: ReadingPlanDay
    ) {
        guard actionTask == nil, let plan else { return }
        guard let onPerformAction else {
            actionFailureMessage = DailyReadingActionError.handlerUnavailable.localizedDescription
            return
        }
        guard let planVersificationResolver else {
            actionFailureMessage = DailyReadingActionError
                .versificationResolverUnavailable
                .localizedDescription
            return
        }
        let planVersification: String?
        do {
            planVersification = try planVersificationResolver(plan.planCode)
        } catch {
            actionFailureMessage = error.localizedDescription
            return
        }

        let request: DailyReadingActionRequest
        do {
            request = try DailyReadingActionRequestFactory.makeRequest(
                planID: plan.id,
                planCode: plan.planCode,
                dayNumber: day.dayNumber,
                assignment: assignment,
                planVersification: planVersification,
                kind: kind,
                readingNumbers: readingNumbers
            )
        } catch {
            actionFailureMessage = error.localizedDescription
            return
        }

        let pending = DailyReadingPendingAction(kind: kind, readingNumbers: readingNumbers)
        let generation = UUID()
        actionGeneration = generation
        activeAction = pending
        actionTask = Task { @MainActor in
            let result = await DailyReadingActionExecutor.execute(
                request,
                handler: onPerformAction
            ) {
                for readingNumber in request.readingNumbers {
                    try persistReading(readingNumber, isRead: true, day: day)
                }
            }
            guard actionGeneration == generation, activeAction == pending else { return }
            activeAction = nil
            actionTask = nil
            switch result {
            case .completed where kind == .read:
                if let onReadCompleted {
                    onReadCompleted()
                } else {
                    dismiss()
                }
            case .completed, .cancelled:
                break
            case .failed(let message):
                actionFailureMessage = message
            }
        }
    }

    /** Cancels in-flight reader work and invalidates its late completion. */
    private func cancelReadingAction() {
        actionTask?.cancel()
        actionTask = nil
        activeAction = nil
        actionGeneration = UUID()
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
                    Text("Day \(day.dayNumber)")
                        .font(.subheadline.weight(idx == currentDayIndex ? .bold : .regular))
                        .frame(width: 60, alignment: .leading)

                    Text(ReadingPlanDayAssignment(rawValue: day.readings).readings.joined(separator: ", "))
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
     - selects only an assignment whose sparse Android day key equals the expected current day
     */
    private func loadPlan() {
        let store = ReadingPlanStore(modelContext: modelContext)
        plan = store.plan(id: planId)

        if let plan {
            sortedDays = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
            do {
                _ = try progressStore.migrateLegacyStatuses(in: plan)
            } catch {
                actionFailureMessage = error.localizedDescription
            }
            let expected = ReadingPlanService.expectedDay(for: plan)
            currentDayIndex = sortedDays.firstIndex { $0.dayNumber == expected } ?? -1
        }
    }

    /**
     Applies Android's "set current day" action to the currently selected day.

     Side effects:
     - mutates the loaded plan through `ReadingPlanService`
     - reloads local view state from SwiftData after saving
     */
    private func setSelectedDayAsCurrent() {
        guard let plan, let currentDay else { return }
        do {
            try ReadingPlanService.setCurrentDay(
                currentDay.dayNumber,
                for: plan,
                modelContext: modelContext,
                progressStore: progressStore
            )
            loadPlan()
        } catch {
            actionFailureMessage = error.localizedDescription
        }
    }

    /**
     Opens the start-date picker initialized with the loaded plan's current start date.

     Side effects:
     - mutates `draftStartDate`
     - presents the start-date sheet
     */
    private func presentStartDatePicker() {
        guard let plan else { return }
        draftStartDate = plan.startDate
        showStartDatePicker = true
    }

    /**
     Persists the draft start date and reloads daily-reading state.

     Side effects:
     - updates the loaded plan through `ReadingPlanService`
     - dismisses the picker sheet
     - reloads local view state from SwiftData after saving
     */
    private func applyDraftStartDate() {
        guard let plan else { return }
        do {
            try ReadingPlanService.setStartDate(
                draftStartDate,
                for: plan,
                modelContext: modelContext,
                settingsStore: SettingsStore(modelContext: modelContext)
            )
            showStartDatePicker = false
            loadPlan()
        } catch {
            actionFailureMessage = error.localizedDescription
        }
    }

    /**
     Deletes the current plan graph and returns to the reading-plan list.

     Side effects:
     - deletes the loaded plan through `ReadingPlanService`
     - clears local view state
     - dismisses the navigation destination after saving
     */
    private func resetCurrentPlan() {
        guard let plan else { return }
        do {
            try ReadingPlanService.resetPlan(
                plan,
                modelContext: modelContext,
                progressStore: progressStore,
                selectionStore: selectionStore
            )
            self.plan = nil
            sortedDays = []
            dismiss()
        } catch {
            actionFailureMessage = error.localizedDescription
        }
    }

    /// Reads one day's effective Android status and registers the state refresh dependency.
    private func status(for day: ReadingPlanDay) -> AndroidReadingPlanStatusPayload {
        _ = statusRevision
        guard let plan else { return AndroidReadingPlanStatusPayload() }
        do {
            return try progressStore.status(for: day, in: plan)
        } catch {
            Task { @MainActor in
                actionFailureMessage = error.localizedDescription
            }
            return AndroidReadingPlanStatusPayload()
        }
    }

    /// Whether Android allows explicit status edits for this displayed day.
    private func isReadingEditable(_ day: ReadingPlanDay) -> Bool {
        guard let plan else { return false }
        return ReadingPlanService.isDateBased(plan) || day.dayNumber >= max(plan.currentDay, 1)
    }

    /// Persists one Android reading-number toggle without collapsing partial completion.
    private func setReading(_ readingNumber: Int, isRead: Bool, day: ReadingPlanDay) {
        do {
            try persistReading(readingNumber, isRead: isRead, day: day)
        } catch {
            actionFailureMessage = error.localizedDescription
        }
    }

    /** Persists one reading mutation and exposes any storage or journal failure to its caller. */
    private func persistReading(
        _ readingNumber: Int,
        isRead: Bool,
        day: ReadingPlanDay
    ) throws {
        guard let plan else { return }
        _ = try progressStore.setReading(
            readingNumber,
            isRead: isRead,
            day: day,
            plan: plan
        )
        statusRevision += 1
    }

    /// Applies Android's enabled Done transition and selects the returned due day.
    private func finishDay(_ day: ReadingPlanDay) {
        guard let plan else { return }
        do {
            let nextDay = try ReadingPlanService.finishDay(
                day,
                in: plan,
                modelContext: modelContext,
                progressStore: progressStore,
                selectionStore: selectionStore
            )
            statusRevision += 1
            guard let nextDay else {
                self.plan = nil
                sortedDays = []
                dismiss()
                return
            }
            if let nextIndex = sortedDays.firstIndex(where: { $0.dayNumber == nextDay }) {
                currentDayIndex = nextIndex
            }
        } catch {
            actionFailureMessage = error.localizedDescription
        }
    }
}

/** Stable identity for one Daily Reading operation represented by progress UI. */
private struct DailyReadingPendingAction: Equatable {
    /// Read or speech operation.
    let kind: DailyReadingActionKind

    /// One-based reading positions represented by the operation.
    let readingNumbers: [Int]
}

/** iOS checkbox presentation for Android's per-reading completion control. */
private struct ReadingPlanCheckboxToggleStyle: ToggleStyle {
    /**
     Builds a stable checkbox row while preserving SwiftUI toggle semantics.

     - Parameter configuration: Toggle binding and caller-provided passage label.
     - Returns: Plain button row with a familiar square/checkmark control.
     - Side effects: Tapping flips the supplied toggle binding.
     - Failure modes: none.
     */
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
