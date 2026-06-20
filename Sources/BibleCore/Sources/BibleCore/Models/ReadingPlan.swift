// ReadingPlan.swift -- Reading plan domain models

import Foundation
import SwiftData

/**
 Persists an active or historical reading plan instance for one user.

 A `ReadingPlan` tracks the selected plan definition, the user's start date, the current
 progress pointer, and the child `ReadingPlanDay` rows that record per-day completion.
 Deleting a plan cascades to its day rows.
 */
@Model
public final class ReadingPlan {
    /// Stable identifier used for SwiftData identity and sync-safe plan references.
    public var id: UUID = UUID()

    /// Stable plan code used to map this record back to a bundled or imported definition.
    public var planCode: String = ""

    /// User-visible plan name captured at start time for display in history and progress UI.
    public var planName: String = ""

    /// Date the user started the plan; used to compute expected day progression.
    public var startDate: Date = Date()

    /// Persisted current-day field retained for parity/backup flows; new plans initialize it to `0`.
    public var currentDay: Int = 0

    /// Total number of day rows the plan definition expects.
    public var totalDays: Int = 365

    /// Marks whether the plan should be treated as the actively followed plan.
    public var isActive: Bool = true

    /// Child day rows that store readings and completion state for each plan day.
    @Relationship(deleteRule: .cascade, inverse: \ReadingPlanDay.plan)
    public var days: [ReadingPlanDay]?

    /**
     Creates a reading plan persistence record.

     - Parameters:
       - id: Stable identifier for SwiftData persistence and cross-entity references.
       - planCode: Definition code for a bundled or imported plan.
       - planName: Display name shown to the user.
       - startDate: Date the user started following the plan.
       - currentDay: Persisted current-day field retained for parity and backup data.
       - totalDays: Total number of plan days expected by the definition.
       - isActive: Whether this plan is the one the app should surface as current.
     */
    public init(
        id: UUID = UUID(),
        planCode: String = "",
        planName: String = "",
        startDate: Date = Date(),
        currentDay: Int = 0,
        totalDays: Int = 365,
        isActive: Bool = true
    ) {
        self.id = id
        self.planCode = planCode
        self.planName = planName
        self.startDate = startDate
        self.currentDay = currentDay
        self.totalDays = totalDays
        self.isActive = isActive
    }
}

/**
 Persists one day's assignment and completion state for a `ReadingPlan`.

 The model keeps the canonical reading string exactly as imported or generated so the
 parsing and rendering layers can interpret it later without lossy transformation.
 */
@Model
public final class ReadingPlanDay {
    /// Stable identifier used for SwiftData identity and day-level updates.
    public var id: UUID = UUID()

    /// Parent plan that owns this day row.
    public var plan: ReadingPlan?

    /// One-based day number within the parent plan definition.
    public var dayNumber: Int = 0

    /// Marks whether the user has completed this day's readings.
    public var isCompleted: Bool = false

    /// Timestamp recorded when the day was marked complete; nil means incomplete.
    public var completedDate: Date?

    /// Canonical reading assignment string, typically semicolon-separated Bible references.
    public var readings: String = ""

    /**
     Creates a reading plan day record.

     - Parameters:
       - id: Stable identifier for SwiftData persistence.
       - dayNumber: One-based index within the parent plan.
       - isCompleted: Whether the day has already been completed.
       - readings: Canonical reading assignment string for this day.
     */
    public init(
        id: UUID = UUID(),
        dayNumber: Int = 0,
        isCompleted: Bool = false,
        readings: String = ""
    ) {
        self.id = id
        self.dayNumber = dayNumber
        self.isCompleted = isCompleted
        self.readings = readings
    }
}
