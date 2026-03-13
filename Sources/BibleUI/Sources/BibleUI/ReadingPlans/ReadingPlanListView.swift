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

 Side effects:
 - starting a template creates a new persisted reading plan
 - deleting rows removes plans from SwiftData
 - presenting the available-plan sheet can also import a custom plan file
 */
public struct ReadingPlanListView: View {
    /// SwiftData context used to create and delete plans.
    @Environment(\.modelContext) private var modelContext

    /// All persisted plans ordered by most recent start date.
    @Query(sort: \ReadingPlan.startDate, order: .reverse) private var plans: [ReadingPlan]

    /// Whether the available-plan picker sheet is presented.
    @State private var showAvailablePlans = false

    /**
     Creates the reading-plan list screen.

     - Note: This initializer has no inputs and performs no side effects.
     */
    public init() {}

    /// Active plans still in progress.
    private var activePlans: [ReadingPlan] {
        plans.filter { $0.isActive }
    }

    /// Completed plans no longer marked active.
    private var completedPlans: [ReadingPlan] {
        plans.filter { !$0.isActive }
    }

    /**
     Builds the empty state or reading-plan list with the available-plan sheet.
     */
    public var body: some View {
        Group {
            if plans.isEmpty {
                ContentUnavailableView(
                    String(localized: "reading_plan_no_plans"),
                    systemImage: "calendar",
                    description: Text(String(localized: "reading_plan_no_plans_description"))
                )
                .accessibilityIdentifier("readingPlanListScreen")
            } else {
                planList
                    .accessibilityIdentifier("readingPlanListScreen")
            }
        }
        .navigationTitle(String(localized: "reading_plans"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "reading_plan_start"), systemImage: "plus") {
                    showAvailablePlans = true
                }
                .accessibilityIdentifier("readingPlanStartButton")
            }
        }
        .sheet(isPresented: $showAvailablePlans) {
            NavigationStack {
                AvailablePlansView { template in
                    let _ = ReadingPlanService.startPlan(
                        template: template,
                        modelContext: modelContext
                    )
                    showAvailablePlans = false
                }
            }
            .presentationDetents([.large])
        }
    }

    /// List grouped into active and completed plan sections.
    private var planList: some View {
        List {
            if !activePlans.isEmpty {
                Section(String(localized: "reading_plan_active")) {
                    ForEach(activePlans) { plan in
                        NavigationLink {
                            DailyReadingView(planId: plan.id)
                        } label: {
                            ActivePlanRow(plan: plan)
                        }
                        .accessibilityIdentifier("readingPlanActivePlanLink")
                        .accessibilityLabel(plan.planName)
                        .accessibilityValue(plan.planCode)
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "delete"), role: .destructive) {
                                modelContext.delete(plan)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }

            if !completedPlans.isEmpty {
                Section(String(localized: "reading_plan_completed")) {
                    ForEach(completedPlans) { plan in
                        CompletedPlanRow(plan: plan)
                            .swipeActions(edge: .trailing) {
                                Button(String(localized: "delete"), role: .destructive) {
                                    modelContext.delete(plan)
                                    try? modelContext.save()
                                }
                            }
                    }
                }
            }
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

    /// Dismiss action for the sheet.
    @Environment(\.dismiss) private var dismiss

    /// Whether the custom-plan file importer is currently presented.
    @State private var showImportPicker = false

    /// Latest user-visible custom-plan import error.
    @State private var importError: String?

    /// Builds the built-in template list, custom import action, and error section.
    var body: some View {
        List {
            Section {
                ForEach(ReadingPlanService.availablePlans) { template in
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
    }

    /**
     Handles custom reading-plan import results from the file importer.

     Side effects:
     - starts and stops security-scoped resource access for the selected file
     - parses custom `.properties`-style plan text through `ReadingPlanService`
     - updates `importError` or forwards the parsed template to `onSelect`
     */
    private func handleCustomPlanImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                importError = String(localized: "reading_plan_import_error_read")
                return
            }

            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            guard let template = ReadingPlanService.importCustomPlan(name: name, propertiesText: text) else {
                importError = String(localized: "reading_plan_import_error_format")
                return
            }

            importError = nil
            onSelect(template)

        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}
