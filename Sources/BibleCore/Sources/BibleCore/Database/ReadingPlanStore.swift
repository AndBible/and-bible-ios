// ReadingPlanStore.swift — Reading plan persistence

import Foundation
import SwiftData

/**
 * Manages reading plan persistence in SwiftData.
 *
 * This store handles durable CRUD for `ReadingPlan` graphs and eagerly saves after mutations so
 * progress UI stays consistent. It does not decide which day is current or which readings belong
 * to a day; that higher-level behavior lives in `ReadingPlanService`.
 *
 * - Important: This type inherits the thread/actor confinement of the supplied `ModelContext`.
 */
@Observable
public final class ReadingPlanStore {
    /// SwiftData context used for all reading-plan reads and writes.
    private let modelContext: ModelContext

    /**
     * Creates a reading-plan store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for reading-plan persistence.
     * - Important: The caller owns context lifecycle and confinement.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     * Fetches all reading plans ordered by most recent `startDate` first.
     * - Returns: Persisted reading plans.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func plans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Fetches only active reading plans.
     * - Returns: Plans whose `isActive` flag is `true`.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func activePlans() -> [ReadingPlan] {
        let descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.isActive }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Fetches a reading plan by primary key.
     * - Parameter id: Plan UUID.
     * - Returns: The plan when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func plan(id: UUID) -> ReadingPlan? {
        var descriptor = FetchDescriptor<ReadingPlan>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Inserts a new reading plan and immediately saves the context.
     * - Parameter plan: Plan to persist.
     * - Side Effects: Inserts the plan graph into SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ plan: ReadingPlan) {
        modelContext.insert(plan)
        save()
    }

    /**
     * Marks a reading-plan day as completed and stamps `completedDate`.
     * - Parameter day: Day record to mutate.
     * - Side Effects: Mutates the supplied `ReadingPlanDay` and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: This method is idempotent for already-completed days because it simply rewrites the same completion fields.
     */
    public func completeDay(_ day: ReadingPlanDay) {
        day.isCompleted = true
        day.completedDate = Date()
        save()
    }

    /**
     * Deletes a reading plan and relies on cascade rules for child day records.
     * - Parameter plan: Plan to delete.
     * - Side Effects: Removes the plan graph from SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ plan: ReadingPlan) {
        modelContext.delete(plan)
        save()
    }

    /**
     * Saves pending reading-plan mutations.
     * - Side Effects: Flushes `modelContext` to disk.
     * - Failure: Save errors are swallowed.
     */
    private func save() {
        try? modelContext.save()
    }
}
