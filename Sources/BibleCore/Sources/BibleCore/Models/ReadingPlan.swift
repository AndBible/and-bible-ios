// ReadingPlan.swift — Reading plan domain models

import Foundation
import SwiftData

/// A reading plan that guides daily Bible reading through a set schedule.
@Model
public final class ReadingPlan {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// Plan identifier (e.g., "chronological", "one_year").
    public var planCode: String

    /// User-visible plan name.
    public var planName: String

    /// Date the user started this plan.
    public var startDate: Date

    /// Current day number in the plan (0-based).
    public var currentDay: Int

    /// Total number of days in the plan.
    public var totalDays: Int

    /// Whether the plan is currently active.
    public var isActive: Bool

    /// Daily reading progress entries.
    @Relationship(deleteRule: .cascade, inverse: \ReadingPlanDay.plan)
    public var days: [ReadingPlanDay]?

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

/// A single day's reading assignment in a reading plan.
@Model
public final class ReadingPlanDay {
    /// UUID primary key.
    @Attribute(.unique) public var id: UUID

    /// Parent reading plan.
    public var plan: ReadingPlan?

    /// Day number (0-based).
    public var dayNumber: Int

    /// Whether this day's reading has been completed.
    public var isCompleted: Bool

    /// Date when this day was marked as completed.
    public var completedDate: Date?

    /// The reading passages for this day (semicolon-separated references).
    public var readings: String

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
