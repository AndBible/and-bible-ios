// ReadingPlanListView.swift — Reading plan list

import SwiftUI
import SwiftData
import BibleCore
import UniformTypeIdentifiers

/// Lists available and active reading plans.
public struct ReadingPlanListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReadingPlan.startDate, order: .reverse) private var plans: [ReadingPlan]
    @State private var showAvailablePlans = false

    public init() {}

    private var activePlans: [ReadingPlan] {
        plans.filter { $0.isActive }
    }

    private var completedPlans: [ReadingPlan] {
        plans.filter { !$0.isActive }
    }

    public var body: some View {
        Group {
            if plans.isEmpty {
                ContentUnavailableView(
                    String(localized: "reading_plan_no_plans"),
                    systemImage: "calendar",
                    description: Text(String(localized: "reading_plan_no_plans_description"))
                )
            } else {
                planList
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

private struct ActivePlanRow: View {
    let plan: ReadingPlan

    private var progress: Double {
        ReadingPlanService.completionPercentage(for: plan)
    }

    private var expectedDay: Int {
        ReadingPlanService.expectedDay(for: plan)
    }

    private var daysCompleted: Int {
        plan.days?.filter(\.isCompleted).count ?? 0
    }

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

private struct CompletedPlanRow: View {
    let plan: ReadingPlan

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

private struct AvailablePlansView: View {
    let onSelect: (ReadingPlanTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImportPicker = false
    @State private var importError: String?

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
