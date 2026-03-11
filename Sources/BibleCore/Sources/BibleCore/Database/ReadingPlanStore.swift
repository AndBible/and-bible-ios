// ReadingPlanStore.swift — Reading plan persistence

import Foundation
import SwiftData

/// Manages reading plan persistence.
@Observable
public final class ReadingPlanStore {
    private let modelContext: ModelContext

    /// Creates a reading-plan store bound to the caller's SwiftData context.
    /// - Parameter modelContext: Context used for reading-plan persistence.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Fetches all reading plans ordered by most recent `startDate` first.
    /// - Returns: Persisted reading plans.
    public func plans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetches only active reading plans.
    /// - Returns: Plans whose `isActive` flag is `true`.
    public func activePlans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.isActive }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetches a reading plan by primary key.
    /// - Parameter id: Plan UUID.
    /// - Returns: The plan when found, otherwise `nil`.
    public func plan(id: UUID) -> ReadingPlan? {
        var descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Inserts a new reading plan and immediately saves the context.
    /// - Parameter plan: Plan to persist.
    public func insert(_ plan: ReadingPlan) {
        modelContext.insert(plan)
        save()
    }

    /// Marks a reading-plan day as completed and stamps `completedDate`.
    /// - Parameter day: Day record to mutate.
    public func completeDay(_ day: ReadingPlanDay) {
        day.isCompleted = true
        day.completedDate = Date()
        save()
    }

    /// Deletes a reading plan and relies on cascade rules for child day records.
    /// - Parameter plan: Plan to delete.
    public func delete(_ plan: ReadingPlan) {
        modelContext.delete(plan)
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}
