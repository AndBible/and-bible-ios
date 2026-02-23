// ReadingPlanStore.swift — Reading plan persistence

import Foundation
import SwiftData

/// Manages reading plan persistence.
@Observable
public final class ReadingPlanStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Fetch all reading plans.
    public func plans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch active reading plans.
    public func activePlans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.isActive }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch a reading plan by ID.
    public func plan(id: UUID) -> ReadingPlan? {
        var descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Insert a new reading plan.
    public func insert(_ plan: ReadingPlan) {
        modelContext.insert(plan)
        save()
    }

    /// Mark a day as completed.
    public func completeDay(_ day: ReadingPlanDay) {
        day.isCompleted = true
        day.completedDate = Date()
        save()
    }

    /// Delete a reading plan.
    public func delete(_ plan: ReadingPlan) {
        modelContext.delete(plan)
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}
