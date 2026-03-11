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

/// Provides built-in reading plan templates and plan lifecycle helpers.
///
/// The service has two plan sources:
/// - Android-parity `.properties` plans loaded from bundled resources
/// - a small set of iOS-specific algorithmic plans
///
/// Day numbering is intentionally 1-based for plan templates and day rows. The persisted
/// `ReadingPlan.currentDay` field is still stored separately and currently starts at `0` when a
/// plan is created.
public final class ReadingPlanService {

    /// All available built-in plans. Data-driven plans are loaded from bundled .properties files
    /// matching the Android AndBible reading plan format.
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

        // iOS-specific algorithmic plans (no Android equivalent)
        plans.append(ntIn90Days)
        plans.append(psalmsProverbs)

        return plans
    }()

    // MARK: - .properties File Parser

    /// Load a reading plan from a bundled .properties file.
    /// Returns a dictionary mapping 1-based day number to the readings string.
    private static func loadPropertiesPlan(code: String) -> [Int: String]? {
        guard let url = Bundle.module.url(
            forResource: code,
            withExtension: "properties",
            subdirectory: "Resources/readingplan"
        ) else { return nil }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        return parseProperties(contents)
    }

    /// Parse .properties file content into a day→readings dictionary.
    /// Format: `dayNumber=OsisRef1,OsisRef2,...`
    /// Lines starting with # are comments. Blank lines are ignored.
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

    // MARK: - Algorithmic Plans (iOS-specific)

    private static let ntIn90Days = ReadingPlanTemplate(
        code: "nt_90",
        name: "New Testament in 90 Days",
        description: "Read through the entire New Testament in 90 days.",
        totalDays: 90,
        readingsForDay: { day in
            // 260 NT chapters / 90 days = ~2.9 chapters/day
            let chaptersPerDay = 3
            let ntBooks = ntBookChapters
            let startChapter = (day - 1) * chaptersPerDay
            var remaining = startChapter
            var readings: [String] = []

            for _ in 0..<chaptersPerDay {
                var accumulated = 0
                for (book, chapters) in ntBooks {
                    if remaining < accumulated + chapters {
                        let ch = remaining - accumulated + 1
                        readings.append("\(book).\(ch)")
                        break
                    }
                    accumulated += chapters
                }
                remaining += 1
            }

            return readings.isEmpty ? "Matt.1" : readings.joined(separator: ",")
        }
    )

    private static let psalmsProverbs = ReadingPlanTemplate(
        code: "psalms_proverbs",
        name: "Psalms & Proverbs",
        description: "Read through Psalms and Proverbs in 60 days.",
        totalDays: 60,
        readingsForDay: { day in
            if day <= 30 {
                // Psalms: 150 chapters / 30 days = 5 per day
                let start = (day - 1) * 5 + 1
                let end = min(start + 4, 150)
                return "Ps.\(start)-Ps.\(end)"
            } else {
                // Proverbs: 31 chapters / 30 days = ~1 per day
                let ch = (day - 31) % 31 + 1
                return "Prov.\(ch)"
            }
        }
    )

    // MARK: - Custom Plan Import

    /// Imports a custom reading plan from `.properties` file content.
    /// - Parameters:
    ///   - name: User-visible plan name.
    ///   - propertiesText: Raw `.properties` file content using Android plan syntax.
    /// - Returns: A transient template when parsing succeeds, otherwise `nil`.
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

    /// Starts a new persisted reading plan from a template.
    /// - Parameters:
    ///   - template: Template defining day count and daily readings.
    ///   - modelContext: Context used to insert the plan and all child day rows.
    /// - Returns: The newly created persisted plan.
    /// - Note: This pre-generates all `ReadingPlanDay` rows up front with 1-based day numbers.
    public static func startPlan(
        template: ReadingPlanTemplate,
        modelContext: ModelContext
    ) -> ReadingPlan {
        let plan = ReadingPlan(
            planCode: template.code,
            planName: template.name,
            startDate: Date(),
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

    /// Calculates which 1-based day the user should be on based on the plan start date.
    /// - Parameter plan: Persisted reading plan.
    /// - Returns: Clamped expected day number in the range `1...plan.totalDays`.
    public static func expectedDay(for plan: ReadingPlan) -> Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: plan.startDate, to: Date()).day ?? 0
        return min(max(days + 1, 1), plan.totalDays)
    }

    /// Calculates completion percentage from the number of completed day rows.
    /// - Parameter plan: Persisted reading plan.
    /// - Returns: Completion percentage as a value between `0` and `1`.
    public static func completionPercentage(for plan: ReadingPlan) -> Double {
        let completedDays = plan.days?.filter(\.isCompleted).count ?? 0
        return plan.totalDays > 0 ? Double(completedDays) / Double(plan.totalDays) : 0
    }

    // MARK: - Bible Reference Helpers

    private static let ntBookChapters: [(String, Int)] = [
        ("Matt", 28), ("Mark", 16), ("Luke", 24), ("John", 21),
        ("Acts", 28), ("Rom", 16), ("1Cor", 16), ("2Cor", 13),
        ("Gal", 6), ("Eph", 6), ("Phil", 4), ("Col", 4),
        ("1Thess", 5), ("2Thess", 3), ("1Tim", 6), ("2Tim", 4),
        ("Titus", 3), ("Phlm", 1), ("Heb", 13), ("Jas", 5),
        ("1Pet", 5), ("2Pet", 3), ("1John", 5), ("2John", 1),
        ("3John", 1), ("Jude", 1), ("Rev", 22)
    ]
}
