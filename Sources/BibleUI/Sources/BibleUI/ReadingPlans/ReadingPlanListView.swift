// ReadingPlanListView.swift — Reading plan list

import SwiftUI
import SwiftData
import BibleCore
import UniformTypeIdentifiers

/**
 Lists active and completed reading plans and starts new plans from built-in or imported templates.

 The screen separates active plans from completed plans, presents the available-plan picker, and
 creates new `ReadingPlan` rows through `ReadingPlanService`.

 Data dependencies:
 - `modelContext` persists started or deleted plans
 - `plans` is a live SwiftData query ordered by most recent start date
 - action callbacks supply exact plan versification and parent-owned active-module behavior

 Side effects:
 - starting a template creates a new persisted reading plan
 - deleting rows removes plans from SwiftData
 - presenting the available-plan sheet can also import a custom plan file
 */
public struct ReadingPlanListView: View {
    /// Destinations owned by the reading-plan list while it remains inside the reader stack.
    private enum ReadingPlanListRoute: Identifiable, Hashable {
        /// Daily-reading view for a plan that was just started from the selector.
        case dailyReading(UUID)

        /// Stable route identity used by SwiftUI's item-based navigation destination.
        var id: String {
            switch self {
            case .dailyReading(let planID):
                return "dailyReading::\(planID.uuidString)"
            }
        }
    }

    /// SwiftData context used to create and delete plans.
    @Environment(\.modelContext) private var modelContext

    /// All persisted plans ordered by most recent start date.
    @Query(sort: \ReadingPlan.startDate, order: .reverse) private var plans: [ReadingPlan]

    /// Whether the available-plan picker sheet is presented.
    @State private var showAvailablePlans = false

    /// Route pushed after a new plan is created from the available-plan selector.
    @State private var activeReadingPlanRoute: ReadingPlanListRoute?

    /// New plan identifier waiting for the selector sheet to dismiss before navigation.
    @State private var pendingStartedPlanID: UUID?

    /// Exact Android plan code selected through the `reading_plan` preference.
    @State private var selectedPlanCode: String?

    /// Fail-visible durable definition recovery error encountered before catalog use.
    @State private var definitionRecoveryError: String?

    /// Loads an optional raw versification, throwing when the plan definition is unavailable.
    let planVersificationResolver: ReadingPlanVersificationResolver?

    /// Performs Android-compatible active-module mapping and the requested Read/Speak operation.
    let onPerformDailyReadingAction: DailyReadingActionHandler?

    /// Closes the reading-plan stack after a successful, durably recorded Read action.
    let onReadCompleted: (@MainActor () -> Void)?

    /**
     Creates the reading-plan list screen.

     - Parameters:
       - planVersificationResolver: Loads one plan code's optional raw JSword versification value,
         throwing when the definition itself is unavailable.
       - onPerformDailyReadingAction: Maps, validates, and performs typed Daily Reading requests.
       - onReadCompleted: Returns from Daily Reading to the owning Bible reader after progress saves.
     - Note: Initialization performs no side effects.
     */
    public init(
        planVersificationResolver: ReadingPlanVersificationResolver? = nil,
        onPerformDailyReadingAction: DailyReadingActionHandler? = nil,
        onReadCompleted: (@MainActor () -> Void)? = nil
    ) {
        self.planVersificationResolver = planVersificationResolver
        self.onPerformDailyReadingAction = onPerformDailyReadingAction
        self.onReadCompleted = onReadCompleted
    }

    /// Active plans still in progress.
    private var activePlans: [ReadingPlan] {
        plans.filter { $0.planCode == selectedPlanCode }
    }

    /// Completed plans no longer marked active.
    private var completedPlans: [ReadingPlan] {
        plans.filter { $0.planCode != selectedPlanCode }
    }

    /**
     Builds the empty state or reading-plan list with the available-plan sheet.
     */
    public var body: some View {
        Group {
            if plans.isEmpty {
                emptyState
                .accessibilityIdentifier("readingPlanListScreen")
                .accessibilityValue(readingPlanListAccessibilityValue)
            } else {
                planList
                    .accessibilityIdentifier("readingPlanListScreen")
                    .accessibilityValue(readingPlanListAccessibilityValue)
            }
        }
        .overlay(alignment: .topLeading) {
            readingPlanListStateExport
        }
        .navigationTitle(String(localized: "reading_plans"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "reading_plan_start"), systemImage: "plus") {
                    presentAvailablePlans()
                }
                .accessibilityIdentifier("readingPlanStartButton")
            }
        }
        .navigationDestination(item: $activeReadingPlanRoute) { route in
            readingPlanListDestination(route)
        }
        .navigationDestination(isPresented: $showAvailablePlans) {
            AvailablePlansView(
                onSelect: startSelectedTemplate,
                onImport: importAndStartCustomPlan
            )
        }
        .onChange(of: showAvailablePlans) { _, isPresented in
            guard !isPresented else { return }
            navigateToPendingStartedPlan()
        }
        .onAppear(perform: recoverDefinitionsAndReconcileSelection)
        .overlay {
            if let message = definitionRecoveryError {
                AndroidMyDocumentDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { definitionRecoveryError = nil }
                ])
            }
        }
    }

    /// Empty reading-plan state with the same start affordance Android exposes from the selector path.
    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                String(localized: "reading_plan_no_plans"),
                systemImage: "calendar",
                description: Text(String(localized: "reading_plan_no_plans_description"))
            )

            Button {
                presentAvailablePlans()
            } label: {
                SwiftUI.Label(String(localized: "reading_plan_start"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("readingPlanStartButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens the available-plan selector through one shared state mutation path.
    private func presentAvailablePlans() {
        showAvailablePlans = true
    }

    /**
    Pushes the just-created plan into Daily Reading after the selector destination has returned.

     Side effects:
     - clears `pendingStartedPlanID`
     - sets `activeReadingPlanRoute`, which drives SwiftUI navigation in the parent stack
     */
    private func navigateToPendingStartedPlan() {
        guard let pendingStartedPlanID else { return }
        self.pendingStartedPlanID = nil
        activeReadingPlanRoute = .dailyReading(pendingStartedPlanID)
    }

    /// Builds reading-plan list destinations without adding another modal presentation layer.
    @ViewBuilder
    private func readingPlanListDestination(_ route: ReadingPlanListRoute) -> some View {
        switch route {
        case .dailyReading(let planID):
            DailyReadingView(
                planId: planID,
                planVersificationResolver: planVersificationResolver,
                onPerformAction: onPerformDailyReadingAction,
                onReadCompleted: onReadCompleted
            )
        }
    }

    /// List grouped into active and completed plan sections.
    private var planList: some View {
        List {
            if !activePlans.isEmpty {
                Section(String(localized: "reading_plan_active")) {
                    ForEach(activePlans) { plan in
                        NavigationLink {
                            DailyReadingView(
                                planId: plan.id,
                                planVersificationResolver: planVersificationResolver,
                                onPerformAction: onPerformDailyReadingAction,
                                onReadCompleted: onReadCompleted
                            )
                        } label: {
                            ActivePlanRow(plan: plan)
                        }
                        .accessibilityIdentifier("readingPlanActivePlanLink")
                        .accessibilityLabel(plan.planName)
                        .accessibilityValue(plan.planCode)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deletePlan(plan)
                            } label: {
                                SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                            }
                            .accessibilityIdentifier(readingPlanDeleteButtonIdentifier(for: plan))
                        }
                    }
                }
            }

            if !completedPlans.isEmpty {
                Section(String(localized: "reading_plans")) {
                    ForEach(completedPlans) { plan in
                        Button {
                            selectAndOpen(plan)
                        } label: {
                            ActivePlanRow(plan: plan)
                        }
                        .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deletePlan(plan)
                                } label: {
                                    SwiftUI.Label(String(localized: "delete"), systemImage: "trash")
                                }
                                .accessibilityIdentifier(readingPlanDeleteButtonIdentifier(for: plan))
                            }
                    }
                }
            }
        }
    }

    /// Stable reading-plan list state exported for UI automation.
    private var readingPlanListAccessibilityValue: String {
        let baseState = "total=\(plans.count);active=\(activePlans.count);completed=\(completedPlans.count);showAvailablePlans=\(showAvailablePlans)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let activeTokens = activePlans.prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(readingPlanAccessibilitySegment($0.planCode))|" }
            .joined(separator: ",")
        let completedTokens = completedPlans.prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(readingPlanAccessibilitySegment($0.planCode))|" }
            .joined(separator: ",")
        return "\(baseState);activeRows=\(activeTokens);completedRows=\(completedTokens)"
    }

    /// Compact hidden state probe used by UI tests instead of snapshotting the live list surface.
    @ViewBuilder
    private var readingPlanListStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(readingPlanListAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("readingPlanListStateExport")
                .accessibilityValue(readingPlanListAccessibilityValue)
        }
    }

    /// Stable row-level delete button identifier for UI tests.
    private func readingPlanDeleteButtonIdentifier(for plan: ReadingPlan) -> String {
        "readingPlanDeleteButton::\(readingPlanAccessibilitySegment(plan.planCode))"
    }

    /// Deletes one persisted plan and lets the live query refresh the list sections.
    private func deletePlan(_ plan: ReadingPlan) {
        do {
            try ReadingPlanService.resetPlan(
                plan,
                modelContext: modelContext,
                progressStore: ReadingPlanProgressStore(
                    modelContext: modelContext,
                    settingsStore: SettingsStore(modelContext: modelContext)
                ),
                selectionStore: selectionStore
            )
            withAnimation {
                selectedPlanCode = selectionStore.selectedPlanCode
            }
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }

    /// Android selected-plan preference store for this view's persistence context.
    private var selectionStore: ReadingPlanSelectionStore {
        ReadingPlanSelectionStore(settingsStore: SettingsStore(modelContext: modelContext))
    }

    /// Migrates legacy flags and refreshes the exact Android selected-plan code.
    private func reconcileSelection() throws {
        selectedPlanCode = try selectionStore.reconcile(
            plans,
            modelContext: modelContext
        )?.planCode
    }

    /** Recovers definition publication before any reading-plan catalog or selection lookup. */
    private func recoverDefinitionsAndReconcileSelection() {
        do {
            try ReadingPlanService.recoverCustomPlanDefinitionPublication(
                settingsStore: SettingsStore(modelContext: modelContext)
            )
            definitionRecoveryError = nil
            try reconcileSelection()
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }

    /** Starts one bundled or already-installed template through the existing selection path. */
    private func startSelectedTemplate(_ template: ReadingPlanTemplate) {
        do {
            let plan = try ReadingPlanService.startPlan(
                template: template,
                modelContext: modelContext,
                selectionStore: selectionStore
            )
            finishStartingPlan(plan)
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }

    /** Imports exact bytes and starts or rebuilds their plan through one durable mutation path. */
    private func importAndStartCustomPlan(fileName: String, propertiesData: Data) throws {
        let plan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: fileName,
            propertiesData: propertiesData,
            modelContext: modelContext,
            settingsStore: SettingsStore(modelContext: modelContext)
        )
        finishStartingPlan(plan)
    }

    /** Updates selector and navigation state after either start path returns a persisted plan. */
    private func finishStartingPlan(_ plan: ReadingPlan) {
        selectedPlanCode = plan.planCode
        pendingStartedPlanID = plan.id
        showAvailablePlans = false
    }

    /// Selects an already-started plan without deleting another plan's state, then opens it.
    private func selectAndOpen(_ plan: ReadingPlan) {
        do {
            try selectionStore.select(plan, among: plans, modelContext: modelContext)
            selectedPlanCode = plan.planCode
            activeReadingPlanRoute = .dailyReading(plan.id)
        } catch {
            definitionRecoveryError = error.localizedDescription
        }
    }
}

// MARK: - Active Plan Row

/**
 Row showing progress for one active reading plan.
 */
private struct ActivePlanRow: View {
    /// Persisted reading plan summarized by the row.
    let plan: ReadingPlan

    /// Completion percentage for the plan in the range `0...1`.
    private var progress: Double {
        ReadingPlanService.completionPercentage(for: plan)
    }

    /// One-based day the user is expected to read today.
    private var expectedDay: Int {
        ReadingPlanService.expectedDay(for: plan)
    }

    /// Number of completed days in the plan.
    private var daysCompleted: Int {
        plan.days?.filter(\.isCompleted).count ?? 0
    }

    /// Builds the active-plan summary row with progress bar and completion metrics.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.planName)
                    .font(.headline)
                Spacer()
                Text("Day \(expectedDay)/\(plan.totalDays)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(progress >= 1.0 ? .green : .blue)

            HStack {
                Text("\(daysCompleted) days completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(progress >= 1.0 ? .green : .blue)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Completed Plan Row

/**
 Row summarizing one completed reading plan.
 */
private struct CompletedPlanRow: View {
    /// Persisted completed plan summarized by the row.
    let plan: ReadingPlan

    /// Builds the completed-plan summary row.
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text(plan.planName)
                    .font(.body)
                Text("Started \(plan.startDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Available Plans View

/**
 Sheet listing built-in reading plan templates and the custom-plan file importer.

 Side effects:
 - selecting a template invokes `onSelect`, allowing the parent to create a persisted plan
 - importing a custom plan reads a user-selected file through a security-scoped URL and parses it
 */
private struct AvailablePlansView: View {
    /// Callback invoked when the user chooses a plan template to start.
    let onSelect: (ReadingPlanTemplate) -> Void

    /// Byte-preserving custom import owned by the parent model/settings transaction.
    let onImport: (_ fileName: String, _ propertiesData: Data) throws -> Void

    /// Dismiss action for the sheet.
    @Environment(\.dismiss) private var dismiss

    /// Whether the custom-plan file importer is currently presented.
    @State private var showImportPicker = false

    /// Latest user-visible custom-plan import error.
    @State private var importError: String?

    /// Current Android-parity catalog snapshot used by the selector.
    @State private var catalog = ReadingPlanService.catalog()

    /// Whether Android's duplicate user-plan warning is currently visible.
    @State private var showDuplicateUserPlanWarning = false

    /// Stable available-plan picker state exported for UI automation.
    private var availablePlansAccessibilityValue: String {
        let baseState = "templates=\(catalog.templates.count);importPickerPresented=\(showImportPicker);duplicateUserPlans=\(catalog.duplicateUserPlanCodes.count)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }

        let templateTokens = catalog.templates
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(readingPlanAccessibilitySegment($0.code))|" }
            .joined(separator: ",")
        return "\(baseState);templateRows=\(templateTokens)"
    }

    /// Builds the built-in template list, custom import action, and error section.
    var body: some View {
        List {
            Section {
                ForEach(catalog.templates) { template in
                    Button {
                        onSelect(template)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(template.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(template.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                Image(systemName: "calendar")
                                    .font(.caption)
                                Text("\(template.totalDays) days")
                                    .font(.caption)
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("readingPlanTemplateButton")
                    .accessibilityLabel(template.name)
                    .accessibilityValue(template.code)
                }
            } header: {
                Text(String(localized: "reading_plan_choose"))
            }

            Section {
                Button {
                    showImportPicker = true
                } label: {
                    SwiftUI.Label(String(localized: "reading_plan_import_custom"), systemImage: "arrow.down.doc")
                }
                .accessibilityIdentifier("readingPlanImportButton")
            } header: {
                Text(String(localized: "reading_plan_custom"))
            } footer: {
                Text(String(localized: "reading_plan_import_footer"))
            }

            if let importError {
                Section {
                    Text(importError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .accessibilityIdentifier("availablePlansScreen")
        .accessibilityValue(availablePlansAccessibilityValue)
        .overlay(alignment: .topLeading) {
            availablePlansStateExport
        }
        .onAppear(perform: reloadCatalog)
        .navigationTitle(String(localized: "reading_plan_available"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleCustomPlanImport(result)
        }
        .overlay {
            if showDuplicateUserPlanWarning {
                AndroidMyDocumentDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: duplicateUserPlanWarningMessage, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { showDuplicateUserPlanWarning = false }
                ])
            }
        }
    }

    /// Android duplicate user-plan warning text.
    private var duplicateUserPlanWarningMessage: String {
        String(
            localized: "plan_duplicate_user_plan",
            defaultValue: "There is a user reading plan in sdcard jsword/readingplan with the same name as an internal plan. It can not be listed here. Please rename the file to something else, leaving it's file extension as .properties"
        )
    }

    /**
     Refreshes discovered reading plans whenever the selector is shown.

     Side effects:
     - reads the Android-parity reading-plan catalog
     - presents Android's duplicate user-plan warning when applicable
     */
    private func reloadCatalog() {
        catalog = ReadingPlanService.catalog()
        showDuplicateUserPlanWarning = catalog.hasDuplicateUserPlans
    }

    /// Compact hidden state probe for the available-plan picker.
    @ViewBuilder
    private var availablePlansStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(availablePlansAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("availablePlansStateExport")
                .accessibilityValue(availablePlansAccessibilityValue)
        }
    }

    /**
     Handles custom reading-plan import results from the file importer.

     Side effects:
     - starts and stops security-scoped resource access for the selected file
     - forwards original custom `.properties` bytes without transcoding
     - updates `importError` or invokes the parent's coordinated import transaction
     */
    private func handleCustomPlanImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? ReadingPlanService.readCustomPlanDefinitionData(from: url) else {
                importError = String(localized: "reading_plan_import_error_read")
                return
            }

            do {
                try onImport(
                    url.lastPathComponent,
                    data
                )
            } catch {
                importError = String(localized: "reading_plan_import_error_format")
                return
            }

            importError = nil

        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

/// Sanitizes one reading-plan code for stable accessibility identifiers and state tokens.
private func readingPlanAccessibilitySegment(_ value: String) -> String {
    let mapped = value.unicodeScalars.map { scalar -> String in
        if CharacterSet.alphanumerics.contains(scalar) {
            return String(scalar)
        }
        return "_"
    }
    let collapsed = mapped.joined().replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}
