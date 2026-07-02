// ReadingPlanService.swift — Reading plan definitions and lifecycle management

import Foundation
import SwiftData

/// Built-in reading plan template with daily reading assignments.
public struct ReadingPlanTemplate: Identifiable, Sendable {
    /// Stable plan code used for persistence and lookup.
    public let code: String
    /// User-visible plan name.
    public let name: String
    /// User-visible plan description.
    public let description: String
    /// Total number of days in the plan.
    public let totalDays: Int
    /// Generates the readings string for a given 1-based day number.
    public let readingsForDay: @Sendable (Int) -> String

    /// `Identifiable` conformance backed by the plan code.
    public var id: String { code }
}

/**
 Provides built-in reading plan templates and plan lifecycle helpers.

 The built-in catalog mirrors Android's bundled `.properties` reading-plan assets. Custom imports
 remain transient templates created from user-selected `.properties` content; Android add-on and
 user-plan discovery is intentionally tracked separately from this bundled catalog.

 Day numbering is intentionally 1-based for plan templates and day rows. The persisted
 `ReadingPlan.currentDay` field is still stored separately and currently starts at `0` when a
 plan is created.
 */
public final class ReadingPlanService {

    /**
     All bundled Android reading-plan templates available to start in-app.

     The list is limited to plan codes backed by bundled `.properties` files so picker, sync,
     and restore behavior stays aligned with Android's built-in catalog. Missing resource files
     are skipped rather than represented by empty placeholder templates.
     */
    public static let availablePlans: [ReadingPlanTemplate] = {
        var plans: [ReadingPlanTemplate] = []

        // Android-parity data-driven plans (loaded from .properties files)
        let dataDrivenPlans: [(code: String, name: String, description: String)] = [
            (
                "y1ot1nt1_OTthenNT",
                "1-Year through Bible",
                "Read through the Bible in 1 year, starting in Genesis and finishing in Revelation."
            ),
            (
                "y1ot1nt1_OTandNT",
                "1-Year OT+NT Simultaneously",
                "Read through the Bible in 1 year, with chapters in the OT and NT every day."
            ),
            (
                "y1ot1nt1_chronological",
                "Chronological 1-Year through Bible",
                "Plan based on chronological events in the Bible. The chronological time-line is approximate."
            ),
            (
                "y1ot1nt2_mcheyne",
                "M'Cheyne 1-Year 4-chapter/day",
                "Based on the M'Cheyne reading system with four different readings for family and personal devotions. OT once, NT and Psalms twice per year."
            ),
            (
                "y1ot6nt4_profHorner",
                "Prof. Horner 10-chapter/day",
                "Read 10 chapters per day from 10 different lists that cycle at different rates."
            ),
            (
                "y1ntpspr",
                "NT, Psalms & Proverbs in a Year",
                "Read through the New Testament, Psalms, and Proverbs in one year."
            ),
            (
                "y2ot1ntps2",
                "2-Year Through Bible, NT+PS twice",
                "Read through the Bible in 2 years, reading the NT and Psalms twice."
            ),
        ]

        for plan in dataDrivenPlans {
            if let readings = loadPropertiesPlan(code: plan.code) {
                let totalDays = readings.keys.max() ?? 0
                plans.append(ReadingPlanTemplate(
                    code: plan.code,
                    name: plan.name,
                    description: plan.description,
                    totalDays: totalDays,
                    readingsForDay: { day in
                        readings[day] ?? ""
                    }
                ))
            }
        }

        return plans
    }()

    // MARK: - .properties File Parser

    /**
     Load a reading plan from a bundled .properties file.
     Returns a dictionary mapping 1-based day number to the readings string.
     */
    private static func loadPropertiesPlan(code: String) -> [Int: String]? {
        guard let url = moduleResourceURL(
            forResource: code,
            withExtension: "properties",
            subdirectories: ["readingplan", "Resources/readingplan"]
        ) else { return nil }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        return parseProperties(contents)
    }

    private static func moduleResourceURL(
        forResource name: String,
        withExtension ext: String,
        subdirectories: [String?]
    ) -> URL? {
        for subdirectory in subdirectories {
            if let url = Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }

    /**
     Parse .properties file content into a day→readings dictionary.
     Format: `dayNumber=OsisRef1,OsisRef2,...`
     Lines starting with # are comments. Blank lines are ignored.
     */
    public static func parseProperties(_ text: String) -> [Int: String] {
        var readings: [Int: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Skip non-numeric keys (e.g. "Versification=KJV")
            guard let dayNumber = Int(key) else { continue }
            readings[dayNumber] = value
        }
        return readings
    }

    // MARK: - Custom Plan Import

    /**
     Imports a custom reading plan from `.properties` file content.
     - Parameters:
       - name: User-visible plan name.
       - propertiesText: Raw `.properties` file content using Android plan syntax.
     - Returns: A transient template when parsing succeeds, otherwise `nil`.
     */
    public static func importCustomPlan(name: String, propertiesText: String) -> ReadingPlanTemplate? {
        let readings = parseProperties(propertiesText)
        guard !readings.isEmpty else { return nil }

        let totalDays = readings.keys.max() ?? 0
        let code = "custom_\(UUID().uuidString.prefix(8))"

        return ReadingPlanTemplate(
            code: code,
            name: name,
            description: "Custom imported reading plan (\(totalDays) days).",
            totalDays: totalDays,
            readingsForDay: { day in
                readings[day] ?? ""
            }
        )
    }

    // MARK: - Plan Management

    /**
     Starts a new persisted reading plan from a template.
     - Parameters:
       - template: Template defining day count and daily readings.
       - modelContext: Context used to insert the plan and all child day rows.
     - Returns: The newly created persisted plan.
     - Note: This pre-generates all `ReadingPlanDay` rows up front with 1-based day numbers and
       stores the start date at the local day boundary to mirror Android's truncated plan date.
     */
    public static func startPlan(
        template: ReadingPlanTemplate,
        modelContext: ModelContext
    ) -> ReadingPlan {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        let plan = ReadingPlan(
            planCode: template.code,
            planName: template.name,
            startDate: startDate,
            currentDay: 0,
            totalDays: template.totalDays,
            isActive: true
        )
        modelContext.insert(plan)

        // Pre-generate all day entries
        for day in 1...template.totalDays {
            let planDay = ReadingPlanDay(
                dayNumber: day,
                readings: template.readingsForDay(day)
            )
            planDay.plan = plan
            modelContext.insert(planDay)
        }

        try? modelContext.save()
        return plan
    }

    /**
     Rebases a plan so the supplied 1-based day number is treated as today's current day.

     - Parameters:
       - dayNumber: Desired plan day. Values outside the plan range are clamped to `1...totalDays`.
       - plan: Persisted plan to mutate.
       - modelContext: SwiftData context used to save the plan and day-row mutations.
       - now: Clock value used to derive today's date and completion timestamps.
     - Side effects: Updates `plan.startDate`, `plan.currentDay`, marks all earlier day rows
       completed, refreshes the active flag, and saves the context on a best-effort basis.
     - Note: The selected day and later days are not rewritten, matching Android's current-day
       action which preserves existing status rows outside the prior-day catch-up range.
     */
    public static func setCurrentDay(
        _ dayNumber: Int,
        for plan: ReadingPlan,
        modelContext: ModelContext,
        now: Date = Date()
    ) {
        let upperBound = max(plan.totalDays, 1)
        let clampedDay = min(max(dayNumber, 1), upperBound)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        plan.startDate = calendar.date(byAdding: .day, value: -(clampedDay - 1), to: today) ?? today
        plan.currentDay = clampedDay

        for day in plan.days ?? [] where day.dayNumber < clampedDay {
            day.isCompleted = true
            if day.completedDate == nil {
                day.completedDate = now
            }
        }

        if plan.days?.allSatisfy(\.isCompleted) == true {
            plan.isActive = false
        } else {
            plan.isActive = true
        }
        try? modelContext.save()
    }

    /**
     Sets a plan's start date and refreshes the persisted current-day pointer.

     - Parameters:
       - startDate: New date anchor. The date is normalized to the current calendar's start of day
         and capped at today to match Android's start-date picker.
       - plan: Persisted plan to mutate.
       - modelContext: SwiftData context used to save the plan mutation.
       - now: Clock value used to cap future dates and calculate the resulting current day.
     - Side effects: Updates `plan.startDate`, recalculates `plan.currentDay`, and saves the
       context on a best-effort basis.
     - Note: Day completion statuses are intentionally left untouched so changing the date does not
       rewrite user-authored reading progress.
     */
    public static func setStartDate(
        _ startDate: Date,
        for plan: ReadingPlan,
        modelContext: ModelContext,
        now: Date = Date()
    ) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let requestedStart = calendar.startOfDay(for: startDate)
        plan.startDate = min(requestedStart, today)
        plan.currentDay = expectedDay(for: plan, asOf: now)
        try? modelContext.save()
    }

    /**
     Deletes one persisted reading plan and its cascaded day rows.

     - Parameters:
       - plan: Persisted plan graph to remove.
       - modelContext: SwiftData context used to delete and save the graph.
     - Side effects: Deletes the plan from SwiftData, relies on the model relationship cascade to
       delete `ReadingPlanDay` rows, and saves the context on a best-effort basis.
     */
    public static func resetPlan(
        _ plan: ReadingPlan,
        modelContext: ModelContext
    ) {
        modelContext.delete(plan)
        try? modelContext.save()
    }

    /**
     Calculates which 1-based day the user should be on based on normalized calendar dates.
     - Parameter plan: Persisted reading plan.
     - Parameter now: Clock value used when comparing the plan start date to today.
     - Returns: Clamped expected day number in the range `1...plan.totalDays`.
     */
    public static func expectedDay(for plan: ReadingPlan, asOf now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: plan.startDate)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startDate, to: today).day ?? 0
        return min(max(days + 1, 1), plan.totalDays)
    }

    /**
     Calculates completion percentage from the number of completed day rows.
     - Parameter plan: Persisted reading plan.
     - Returns: Completion percentage as a value between `0` and `1`.
     */
    public static func completionPercentage(for plan: ReadingPlan) -> Double {
        let completedDays = plan.days?.filter(\.isCompleted).count ?? 0
        return plan.totalDays > 0 ? Double(completedDays) / Double(plan.totalDays) : 0
    }

}
