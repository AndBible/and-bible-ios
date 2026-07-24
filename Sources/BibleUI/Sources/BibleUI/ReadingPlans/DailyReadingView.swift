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

    /// Active reader/workspace colors shared with the parent Android activity route.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Android Up action that clears the parent-owned Reading Plan destination.
    private let onDismiss: (() -> Void)?

    /// Opens Android's flat ReadingPlanSelectorList when the plan title is tapped.
    private let onChoosePlan: (() -> Void)?

    /// Leaves Daily Reading after Reset or when Android's Done action has no due follow-up day.
    private let onPlanEnded: (() -> Void)?

    /// Hands Android's Import reading plan command to the owning file-handoff coordinator.
    private let onImportPlan: (() -> Void)?

    /// Reader-owned document labels and speech state shown in Android's action bar.
    private let toolbarState: AndroidDailyReadingToolbarState

    /// Opens the reader's suggested Bible and leaves Daily Reading.
    private let onOpenBible: (() -> Void)?

    /// Opens the reader's suggested commentary and leaves Daily Reading.
    private let onOpenCommentary: (() -> Void)?

    /// Opens the reader's suggested dictionary and leaves Daily Reading.
    private let onOpenDictionary: (() -> Void)?

    /// Pauses or resumes the global speech session without leaving Daily Reading.
    private let onToggleSpeechPause: (() -> Void)?

    /// Stops the global speech session without leaving Daily Reading.
    private let onStopSpeech: (() -> Void)?

    /// SwiftData context used to load and persist plan progress.
    @Environment(\.modelContext) private var modelContext

    /// Loaded reading plan, or `nil` while the view is still hydrating.
    @State private var plan: ReadingPlan?

    /// Zero-based index of the currently selected day in `sortedDays`.
    @State private var currentDayIndex: Int = 0

    /// Reading plan days sorted by ascending day number.
    @State private var sortedDays: [ReadingPlanDay] = []

    /// Whether the Android-style start-date picker dialog is currently presented.
    @State private var showStartDatePicker = false

    /// Draft start date edited in the start-date picker before it is saved.
    @State private var draftStartDate = Date()

    /// Whether the destructive reset confirmation is currently presented.
    @State private var showResetConfirmation = false

    /// Whether Android's Set current day confirmation is currently presented.
    @State private var showSetCurrentDayConfirmation = false

    /// Whether the source overflow popup is currently visible.
    @State private var showsOverflowMenu = false

    /// Whether the app-owned DailyReadingList day selector is currently visible.
    @State private var showsDaySelector = false

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
        surfacePalette = .standard
        onDismiss = nil
        onChoosePlan = nil
        onPlanEnded = nil
        onImportPlan = nil
        toolbarState = .unavailable
        onOpenBible = nil
        onOpenCommentary = nil
        onOpenDictionary = nil
        onToggleSpeechPause = nil
        onStopSpeech = nil
        self.planVersificationResolver = planVersificationResolver
        self.onPerformAction = onPerformAction
        self.onReadCompleted = onReadCompleted
    }

    /**
     Creates the reader-owned Daily Reading activity with app-owned navigation and menu callbacks.

     - Parameters:
       - planId: Persisted plan identifier.
       - surfacePalette: Active reader/workspace palette.
       - onDismiss: Android Up action for the complete Reading Plan route.
       - onChoosePlan: Opens the flat plan selector from the plan title.
       - onPlanEnded: Leaves the activity after Reset or a Done result with no due follow-up day.
       - onImportPlan: Starts the explicit platform file handoff from the overflow command.
       - toolbarState: Active document labels and speech state from the reader owner.
       - onOpenBible: Opens Android's suggested Bible and leaves this activity.
       - onOpenCommentary: Opens Android's suggested commentary and leaves this activity.
       - onOpenDictionary: Opens Android's suggested dictionary and leaves this activity.
       - onToggleSpeechPause: Pauses or resumes the shared speech session.
       - onStopSpeech: Stops the shared speech session.
       - planVersificationResolver: Loads the plan definition's optional versification.
       - onPerformAction: Executes exact Read or Speak requests.
       - onReadCompleted: Closes the reader route after successful Read navigation.
     - Side effects: None during initialization.
     - Failure modes: None during initialization.
     */
    init(
        planId: UUID,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: @escaping () -> Void,
        onChoosePlan: @escaping () -> Void,
        onPlanEnded: @escaping () -> Void,
        onImportPlan: @escaping () -> Void,
        toolbarState: AndroidDailyReadingToolbarState,
        onOpenBible: @escaping () -> Void,
        onOpenCommentary: @escaping () -> Void,
        onOpenDictionary: @escaping () -> Void,
        onToggleSpeechPause: @escaping () -> Void,
        onStopSpeech: @escaping () -> Void,
        planVersificationResolver: ReadingPlanVersificationResolver? = nil,
        onPerformAction: DailyReadingActionHandler? = nil,
        onReadCompleted: (@MainActor () -> Void)? = nil
    ) {
        self.planId = planId
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.onChoosePlan = onChoosePlan
        self.onPlanEnded = onPlanEnded
        self.onImportPlan = onImportPlan
        self.toolbarState = toolbarState
        self.onOpenBible = onOpenBible
        self.onOpenCommentary = onOpenCommentary
        self.onOpenDictionary = onOpenDictionary
        self.onToggleSpeechPause = onToggleSpeechPause
        self.onStopSpeech = onStopSpeech
        self.planVersificationResolver = planVersificationResolver
        self.onPerformAction = onPerformAction
        self.onReadCompleted = onReadCompleted
    }

    /// Currently selected day, or `nil` when the plan has not loaded yet.
    private var currentDay: ReadingPlanDay? {
        guard currentDayIndex >= 0, currentDayIndex < sortedDays.count else { return nil }
        return sortedDays[currentDayIndex]
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

    /** Builds Android's Daily Reading or DailyReadingList activity without native iOS chrome. */
    public var body: some View {
        ZStack {
            surfacePalette.backgroundColor.ignoresSafeArea()

            if showsDaySelector, let plan, !sortedDays.isEmpty {
                daySelector(plan)
            } else if let plan, !sortedDays.isEmpty {
                dailyReadingActivity(plan)
            } else {
                Text(String(localized: "daily_reading_loading", defaultValue: "Loading…"))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .accessibilityIdentifier("dailyReadingScreen")
            }
        }
        .foregroundStyle(surfacePalette.foregroundColor)
        .background(surfacePalette.backgroundColor)
        .overlay {
            if showStartDatePicker {
                AndroidReadingPlanStartDateDialog(
                    selection: $draftStartDate,
                    onCancel: { showStartDatePicker = false },
                    onApply: applyDraftStartDate
                )
            }
        }
        .overlay {
            if showSetCurrentDayConfirmation {
                AndroidDecisionDialog(
                    title: String(localized: "rdg_plan_title", defaultValue: "Reading Plan"),
                    message: String(
                        localized: "msg_set_current_day_reading_plan",
                        defaultValue: "This will set today as the current day in this plan and mark all previous days as read. Continue?"
                    ),
                    actions: [
                        .init(id: "yes", title: String(localized: "yes", defaultValue: "Yes"), style: .normal) {
                            showSetCurrentDayConfirmation = false
                            setSelectedDayAsCurrent()
                        },
                        .init(id: "no", title: String(localized: "no", defaultValue: "No"), style: .normal) {
                            showSetCurrentDayConfirmation = false
                        }
                    ],
                    accessibilityIdentifier: "dailyReadingSetCurrentDayDialog"
                )
            } else if showResetConfirmation {
                AndroidDecisionDialog(
                    title: String(localized: "rdg_plan_title", defaultValue: "Reading Plan"),
                    message: String(
                        localized: "reset_plan_question",
                        defaultValue: "Are you sure you want to reset this plan?"
                    ),
                    actions: [
                        .init(id: "yes", title: String(localized: "yes", defaultValue: "Yes"), style: .destructive) {
                            showResetConfirmation = false
                            resetCurrentPlan()
                        },
                        .init(id: "no", title: String(localized: "no", defaultValue: "No"), style: .normal) {
                            showResetConfirmation = false
                        }
                    ],
                    accessibilityIdentifier: "dailyReadingResetConfirmationDialog"
                )
            } else if let message = actionFailureMessage {
                AndroidDecisionDialog(title: String(localized: "error_occurred", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "ok", defaultValue: "OK"), style: .normal) { actionFailureMessage = nil }
                ], accessibilityIdentifier: "dailyReadingErrorDialog")
            }
        }
        .onAppear {
            loadPlan()
        }
        .onDisappear(perform: cancelReadingAction)
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /** Projects workflow state into the presentation-only Android Daily Reading activity. */
    @ViewBuilder
    private func dailyReadingActivity(_ plan: ReadingPlan) -> some View {
        if let day = currentDay {
            let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
            let dayStatus = status(for: day)
            let readStates = assignment.readings.indices.map { dayStatus.isRead($0 + 1) }
            AndroidDailyReadingActivityView(
                planName: plan.planName,
                dayNumber: day.dayNumber,
                dayTitle: localizedDay(day.dayNumber),
                readingDate: readingDateText(plan: plan, day: day, assignment: assignment),
                readings: assignment.readings,
                readStates: readStates,
                isReadingEditable: isReadingEditable(day),
                isDateBasedPlan: ReadingPlanService.isDateBased(plan),
                isBusy: actionTask != nil,
                activeActionKey: activeAction.map {
                    androidDailyReadingActionKey(kind: $0.kind, readingNumbers: $0.readingNumbers)
                },
                toolbarState: toolbarState,
                surfacePalette: surfacePalette,
                showsOverflowMenu: $showsOverflowMenu,
                onBack: { onDismiss?() },
                onChoosePlan: { onChoosePlan?() },
                onChooseDay: { showsDaySelector = true },
                onOpenBible: { onOpenBible?() },
                onOpenCommentary: { onOpenCommentary?() },
                onOpenDictionary: { onOpenDictionary?() },
                onToggleSpeechPause: { onToggleSpeechPause?() },
                onStopSpeech: { onStopSpeech?() },
                onToggleReading: { readingNumber in
                    setReading(
                        readingNumber,
                        isRead: !status(for: day).isRead(readingNumber),
                        day: day
                    )
                },
                onPerformAction: { kind, readingNumbers in
                    performReadingAction(
                        kind: kind,
                        readingNumbers: readingNumbers,
                        assignment: assignment,
                        day: day
                    )
                },
                onDone: { finishDay(day) },
                onSetCurrentDay: { showSetCurrentDayConfirmation = true },
                onSetStartDate: presentStartDatePicker,
                onReset: { showResetConfirmation = true },
                onImport: { onImportPlan?() }
            )
        } else {
            Text(String(localized: "error_occurred", defaultValue: "Error"))
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Projects stored days into Android's presentation-only `DailyReadingList` activity.
    private func daySelector(_ plan: ReadingPlan) -> some View {
        let rows = sortedDays.map { day in
            let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
            return AndroidDailyReadingDayRow(
                id: day.id,
                dayNumber: day.dayNumber,
                title: daySelectorTitle(plan: plan, day: day, assignment: assignment),
                readings: assignment.readings.joined(separator: ", ")
            )
        }
        return AndroidDailyReadingDaySelectorView(
            rows: rows,
            surfacePalette: surfacePalette,
            onBack: { showsDaySelector = false },
            onSelect: { dayNumber in
                guard let index = sortedDays.firstIndex(where: { $0.dayNumber == dayNumber }) else {
                    return
                }
                currentDayIndex = index
                showsDaySelector = false
            }
        )
    }

    /// Android `Day %s` localization with the plan's one-based day number.
    private func localizedDay(_ dayNumber: Int) -> String {
        String(
            format: String(localized: "rdg_plan_day", defaultValue: "Day %@"),
            String(dayNumber)
        )
    }

    /// Android's localized medium date for one ordinal or date-based plan assignment.
    private func readingDateText(
        plan: ReadingPlan,
        day: ReadingPlanDay,
        assignment: ReadingPlanDayAssignment
    ) -> String {
        let date: Date?
        if assignment.isDateBased {
            date = assignment.scheduledDate(inYearContaining: Date())
        } else {
            date = Calendar.current.date(byAdding: .day, value: day.dayNumber - 1, to: plan.startDate)
        }
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Android DailyReadingList uses the scheduled date for date plans and Day N otherwise.
    private func daySelectorTitle(
        plan: ReadingPlan,
        day: ReadingPlanDay,
        assignment: ReadingPlanDayAssignment
    ) -> String {
        assignment.isDateBased
            ? readingDateText(plan: plan, day: day, assignment: assignment)
            : localizedDay(day.dayNumber)
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
                    onDismiss?()
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
     - presents the Android-style start-date dialog
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
     - dismisses the picker dialog
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
            onPlanEnded?()
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
                onPlanEnded?()
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
