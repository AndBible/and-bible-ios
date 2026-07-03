// ReadingPlanService.swift — Reading plan definitions and lifecycle management

import Foundation
import SwiftData
import SwordKit

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
    /// Whether this template uses Android's date-prefixed reading-plan format.
    public let isDateBased: Bool
    /// Generates the readings string for a given 1-based day number.
    public let readingsForDay: @Sendable (Int) -> String

    /// `Identifiable` conformance backed by the plan code.
    public var id: String { code }

    /**
     Creates one reading-plan template row.

     - Parameters:
       - code: Stable plan code used for persistence and lookup.
       - name: User-visible plan name.
       - description: User-visible plan description.
       - totalDays: Total number of days encoded by the plan.
       - isDateBased: Whether readings use Android's date-prefixed syntax.
       - readingsForDay: Closure returning the readings string for a 1-based day number.
     */
    public init(
        code: String,
        name: String,
        description: String,
        totalDays: Int,
        isDateBased: Bool = false,
        readingsForDay: @escaping @Sendable (Int) -> String
    ) {
        self.code = code
        self.name = name
        self.description = description
        self.totalDays = totalDays
        self.isDateBased = isDateBased
        self.readingsForDay = readingsForDay
    }
}

/**
 Android-parity reading-plan catalog with duplicate user-plan diagnostics.

 Android lists built-in plans first, appends unique files from `jsword/readingplan`, and then appends
 unique plans declared by add-on modules. User files whose codes match built-ins do not create a
 duplicate row, but they do trigger a selector warning and supply the plan content when that code is
 loaded.
 */
public struct ReadingPlanCatalog: Sendable {
    /// Templates visible in the available-plan selector.
    public let templates: [ReadingPlanTemplate]

    /// User reading-plan file codes that duplicate built-in plan codes.
    public let duplicateUserPlanCodes: [String]

    /// Whether the catalog should surface Android's duplicate user-plan warning.
    public var hasDuplicateUserPlans: Bool { !duplicateUserPlanCodes.isEmpty }

    /**
     Creates one catalog snapshot.

     - Parameters:
       - templates: Visible templates in Android selector order.
       - duplicateUserPlanCodes: User file codes that duplicate built-in plan codes.
     */
    public init(templates: [ReadingPlanTemplate], duplicateUserPlanCodes: [String]) {
        self.templates = templates
        self.duplicateUserPlanCodes = duplicateUserPlanCodes
    }
}

/**
 Provides Android-compatible reading plan templates and plan lifecycle helpers.

 The catalog mirrors Android's `ReadingPlanTextFileDao`: bundled `.properties` plans are listed
 first, followed by unique user files from `jsword/readingplan`, followed by unique add-on-provided
 plans declared through `AndBibleProvidesReadingPlan`.

 Day numbering is intentionally 1-based for plan templates and day rows. The persisted
 `ReadingPlan.currentDay` field is still stored separately and currently starts at `0` when a
 plan is created.
 */
public final class ReadingPlanService {
    private struct BundledPlanDefinition: Sendable {
        let code: String
        let name: String
        let description: String
    }

    private struct UserPlanFile: Sendable {
        let code: String
        let url: URL
    }

    private enum PlanSource {
        case bundled
        case userFile(URL)
        case addon(SwordReadingPlanProvider)
    }

    private static let bundledPlanDefinitions: [BundledPlanDefinition] = [
        .init(
            code: "y1ot1nt1_OTthenNT",
            name: "1-Year through Bible",
            description: "Read through the Bible in 1 year, starting in Genesis and finishing in Revelation."
        ),
        .init(
            code: "y1ot1nt1_OTandNT",
            name: "1-Year OT+NT Simultaneously",
            description: "Read through the Bible in 1 year, with chapters in the OT and NT every day."
        ),
        .init(
            code: "y1ot1nt1_chronological",
            name: "Chronological 1-Year through Bible",
            description: "Plan based on chronological events in the Bible. The chronological time-line is approximate."
        ),
        .init(
            code: "y1ot1nt2_mcheyne",
            name: "M'Cheyne 1-Year 4-chapter/day",
            description: "Based on the M'Cheyne reading system with four different readings for family and personal devotions. OT once, NT and Psalms twice per year."
        ),
        .init(
            code: "y1ot6nt4_profHorner",
            name: "Prof. Horner 10-chapter/day",
            description: "Read 10 chapters per day from 10 different lists that cycle at different rates."
        ),
        .init(
            code: "y1ntpspr",
            name: "NT, Psalms & Proverbs in a Year",
            description: "Read through the New Testament, Psalms, and Proverbs in one year."
        ),
        .init(
            code: "y2ot1ntps2",
            name: "2-Year Through Bible, NT+PS twice",
            description: "Read through the Bible in 2 years, reading the NT and Psalms twice."
        ),
    ]

    /**
     Android-compatible reading-plan templates available to start in-app.

     This compatibility view returns the current catalog templates. Call `catalog(...)` when the
     caller also needs duplicate user-plan diagnostics.
     */
    public static var availablePlans: [ReadingPlanTemplate] {
        catalog().templates
    }

    /**
     Default Android-compatible user reading-plan folder in the app sandbox.

     Android uses JSword's `jsword/readingplan` directory for user `.properties` files. iOS mirrors
     that storage boundary under the application documents directory.
     */
    public static func defaultUserReadingPlanDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("jsword/readingplan", isDirectory: true)
    }

    /**
     Builds the Android-parity reading-plan catalog.

     - Parameters:
       - userPlanDirectory: Directory containing Android-compatible user `.properties` plans.
       - modulePath: SWORD module root containing add-on module configs and provider files.
     - Returns: Catalog templates plus duplicate user-plan diagnostics.
     - Side effects: Reads bundled resources, user plan files, SWORD configs, and provider files.
     - Failure modes: Missing or malformed plan files are skipped.
     */
    public static func catalog(
        userPlanDirectory: URL? = ReadingPlanService.defaultUserReadingPlanDirectory(),
        modulePath: String = SwordManager.defaultModulePath()
    ) -> ReadingPlanCatalog {
        let userPlans = userPlanFiles(in: userPlanDirectory)
        let userPlansByCode = Dictionary(userPlans.map { ($0.code, $0.url) }) { first, _ in first }
        let providers = SwordManager.readingPlanProviders(modulePath: modulePath)
        let providersByCode = Dictionary(providers.map { ($0.planCode, $0) }) { _, last in last }
        let bundledCodes = Set(bundledPlanDefinitions.map(\.code))
        var duplicateUserPlanCodes: [String] = []
        var duplicateSeen = Set<String>()
        for userPlan in userPlans where bundledCodes.contains(userPlan.code) {
            if duplicateSeen.insert(userPlan.code).inserted {
                duplicateUserPlanCodes.append(userPlan.code)
            }
        }

        var templates: [ReadingPlanTemplate] = []
        var emittedCodes = Set<String>()

        for definition in bundledPlanDefinitions {
            emittedCodes.insert(definition.code)
            if let template = template(
                code: definition.code,
                bundledDefinition: definition,
                userPlanFile: userPlansByCode[definition.code],
                addonProvider: providersByCode[definition.code]
            ) {
                templates.append(template)
            }
        }

        for userPlan in userPlans where !emittedCodes.contains(userPlan.code) {
            emittedCodes.insert(userPlan.code)
            if let template = template(
                code: userPlan.code,
                bundledDefinition: nil,
                userPlanFile: userPlan.url,
                addonProvider: providersByCode[userPlan.code]
            ) {
                templates.append(template)
            }
        }

        for provider in providers where !emittedCodes.contains(provider.planCode) {
            emittedCodes.insert(provider.planCode)
            if let template = template(
                code: provider.planCode,
                bundledDefinition: nil,
                userPlanFile: nil,
                addonProvider: provider
            ) {
                templates.append(template)
            }
        }

        return ReadingPlanCatalog(
            templates: templates,
            duplicateUserPlanCodes: duplicateUserPlanCodes
        )
    }

    // MARK: - .properties File Parser

    /**
     Creates one template by selecting the Android-equivalent source for a plan code.

     Android loads add-on provider files before user files before bundled assets for the same plan
     code. Built-in display metadata remains attached to bundled codes even when an external file
     supplies the readings.

     - Parameters:
       - code: Plan code being materialized.
       - bundledDefinition: Built-in metadata when the code belongs to Android's internal catalog.
       - userPlanFile: Matching user `.properties` file, when present.
       - addonProvider: Matching add-on provider, when present.
     - Returns: Template when a selected source can be parsed.
     - Side effects: Reads at most one plan file.
     - Failure modes: Missing or malformed selected sources return `nil`.
     */
    private static func template(
        code: String,
        bundledDefinition: BundledPlanDefinition?,
        userPlanFile: URL?,
        addonProvider: SwordReadingPlanProvider?
    ) -> ReadingPlanTemplate? {
        let source: PlanSource
        let selectedPropertiesText: String

        if let addonProvider,
           let text = propertiesText(from: addonProvider.fileURL) {
            source = .addon(addonProvider)
            selectedPropertiesText = text
        } else if let userPlanFile,
                  let text = propertiesText(from: userPlanFile) {
            source = .userFile(userPlanFile)
            selectedPropertiesText = text
        } else if let text = bundledPropertiesText(code: code) {
            source = .bundled
            selectedPropertiesText = text
        } else {
            return nil
        }

        let readings = parseProperties(selectedPropertiesText)
        guard !readings.isEmpty else { return nil }

        let totalDays = readings.keys.max() ?? 0
        let display = displayMetadata(
            code: code,
            bundledDefinition: bundledDefinition,
            source: source,
            propertiesText: selectedPropertiesText
        )
        let isDateBased = isDateBased(source: source, firstDayReadings: readings[1] ?? "")

        return ReadingPlanTemplate(
            code: code,
            name: display.name,
            description: display.description,
            totalDays: totalDays,
            isDateBased: isDateBased,
            readingsForDay: { day in
                readings[day] ?? ""
            }
        )
    }

    /**
     Lists Android-compatible user reading-plan files from one folder.

     - Parameter directory: Folder equivalent to Android's `jsword/readingplan`.
     - Returns: `.properties` files with plan codes derived from file names.
     - Side effects: Reads the directory listing.
     - Failure modes: Missing or unreadable directories return an empty list.
     */
    private static func userPlanFiles(in directory: URL?) -> [UserPlanFile] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.caseInsensitiveCompare("properties") == .orderedSame }
            .compactMap { url -> UserPlanFile? in
                let code = url.deletingPathExtension().lastPathComponent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { return nil }
                return UserPlanFile(code: code, url: url)
            }
    }

    /**
     Reads a bundled Android plan resource as text.

     - Parameter code: Bundled plan code.
     - Returns: Decoded plan text.
     - Side effects: Reads one bundled resource.
     - Failure modes: Missing or undecodable resources return `nil`.
     */
    private static func bundledPropertiesText(code: String) -> String? {
        guard let url = moduleResourceURL(
            forResource: code,
            withExtension: "properties",
            subdirectories: ["readingplan", "Resources/readingplan"]
        ) else { return nil }

        return propertiesText(from: url)
    }

    /**
     Reads one Android `.properties` file using the encodings accepted by local catalog sources.

     - Parameter url: Local plan file URL.
     - Returns: Decoded text.
     - Side effects: Reads `url` from disk.
     - Failure modes: Missing or undecodable files return `nil`.
     */
    private static func propertiesText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .isoLatin1)
    }

    /**
     Resolves display metadata for a selected plan source.

     - Parameters:
       - code: Plan code used as fallback for user plans.
       - bundledDefinition: Built-in metadata when this is an internal Android code.
       - source: Source selected for the plan content.
       - propertiesText: Raw selected plan text.
     - Returns: User-visible name and description.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func displayMetadata(
        code: String,
        bundledDefinition: BundledPlanDefinition?,
        source: PlanSource,
        propertiesText: String
    ) -> (name: String, description: String) {
        if let bundledDefinition {
            return (bundledDefinition.name, bundledDefinition.description)
        }

        switch source {
        case .addon(let provider):
            return (provider.name, provider.description)
        case .userFile:
            return userPlanMetadata(from: propertiesText, fallbackName: code)
        case .bundled:
            return (code, "")
        }
    }

    /**
     Reads Android custom-plan name and description comments.

     Android uses up to the first five physical lines and treats leading `#` comments as name and
     description text. The first comment becomes the name; remaining comments are joined as the
     description.

     - Parameters:
       - text: Raw `.properties` content.
       - fallbackName: Name used when no leading comment name exists.
     - Returns: User-visible name and description.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func userPlanMetadata(
        from text: String,
        fallbackName: String
    ) -> (name: String, description: String) {
        var comments: [String] = []
        for line in text.components(separatedBy: .newlines).prefix(5) {
            guard line.hasPrefix("#") else { continue }
            let comment = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(
                    of: #"^(\s*#*\s*)"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !comment.isEmpty else { continue }
            comments.append(String(comment))
        }

        return (
            comments.first ?? fallbackName,
            comments.dropFirst().joined(separator: " ")
        )
    }

    /**
     Resolves whether the selected source uses Android's date-based plan semantics.

     Add-on providers use the explicit `AndBibleReadingPlanDateBased` metadata, matching Android.
     Bundled and user files fall back to Android's first-day prefix detection.

     - Parameters:
       - source: Plan source selected for content.
       - firstDayReadings: Raw day-one readings string.
     - Returns: `true` when the plan should use date-based completion semantics.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func isDateBased(source: PlanSource, firstDayReadings: String) -> Bool {
        if case .addon(let provider) = source {
            return provider.isDateBased
        }
        return hasDateBasedPrefix(firstDayReadings)
    }

    /**
     Detects Android's date-prefixed reading-plan syntax.

     - Parameter readings: Raw readings string from one day.
     - Returns: `true` when the string starts with a `Mon-1;`-style prefix.
     - Side effects: none.
     - Failure modes: none.
     */
    static func hasDateBasedPrefix(_ readings: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: #"^[A-Za-z]{3}-\d{1,2};"#)
        let range = NSRange(readings.startIndex..<readings.endIndex, in: readings)
        return regex.firstMatch(in: readings, options: [], range: range) != nil
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
        for line in logicalPropertiesLines(from: text) {
            guard let entry = propertiesEntry(from: line) else { continue }
            let key = unescapePropertyText(entry.key).trimmingCharacters(in: .whitespaces)
            let value = unescapePropertyText(entry.value)

            // Skip non-numeric keys (e.g. "Versification=KJV")
            guard let dayNumber = Int(key) else { continue }
            readings[dayNumber] = value
        }
        return readings
    }

    /**
     Builds Java `.properties` logical lines from physical text lines.

     Android loads reading plans through `Properties.load`, where a trailing odd backslash joins the
     next physical line and strips the continuation marker. Leading whitespace on the continued
     line is ignored.

     - Parameter text: Raw `.properties` file content.
     - Returns: Logical property lines ready for key/value parsing.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func logicalPropertiesLines(from text: String) -> [String] {
        var logicalLines: [String] = []
        var current = ""

        for physicalLine in text.components(separatedBy: .newlines) {
            if current.isEmpty {
                current = physicalLine
            } else {
                current += physicalLine.trimmingCharacters(in: .whitespaces)
            }

            if hasOddTrailingBackslashes(current) {
                current.removeLast()
                continue
            }

            logicalLines.append(current)
            current = ""
        }

        if !current.isEmpty {
            logicalLines.append(current)
        }

        return logicalLines
    }

    /**
     Parses one Java `.properties` logical line into a raw key/value pair.

     Separators match Android's `Properties.load` behavior: the first unescaped `=`, `:`, or
     whitespace ends the key, then optional separator characters and leading value whitespace are
     skipped. Blank lines and `#`/`!` comments are ignored.

     - Parameter line: One logical property line.
     - Returns: Raw key and value before escape decoding, or `nil` for ignored lines.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func propertiesEntry(from line: String) -> (key: String, value: String)? {
        let text = String(line.drop(while: isPropertyWhitespace))
        guard let first = text.first, first != "#", first != "!" else { return nil }

        var index = text.startIndex
        var keyEnd = text.endIndex
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "=" || character == ":" || isPropertyWhitespace(character) {
                keyEnd = index
                break
            }
            index = text.index(after: index)
        }

        guard keyEnd < text.endIndex else {
            return (text, "")
        }

        var valueStart = keyEnd
        while valueStart < text.endIndex, isPropertyWhitespace(text[valueStart]) {
            valueStart = text.index(after: valueStart)
        }
        if valueStart < text.endIndex, text[valueStart] == "=" || text[valueStart] == ":" {
            valueStart = text.index(after: valueStart)
        }
        while valueStart < text.endIndex, isPropertyWhitespace(text[valueStart]) {
            valueStart = text.index(after: valueStart)
        }

        return (
            String(text[..<keyEnd]),
            String(text[valueStart...])
        )
    }

    /**
     Decodes Java `.properties` escape sequences used by Android reading-plan files.

     - Parameter text: Raw key or value text.
     - Returns: Text with common Java properties escapes and `\uXXXX` sequences decoded.
     - Side effects: none.
     - Failure modes: Malformed unicode escapes are left as literal escaped text.
     */
    private static func unescapePropertyText(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "\\" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            let escapedIndex = text.index(after: index)
            guard escapedIndex < text.endIndex else {
                index = escapedIndex
                continue
            }

            let escaped = text[escapedIndex]
            switch escaped {
            case "t":
                result.append("\t")
                index = text.index(after: escapedIndex)
            case "n":
                result.append("\n")
                index = text.index(after: escapedIndex)
            case "r":
                result.append("\r")
                index = text.index(after: escapedIndex)
            case "f":
                result.append("\u{000C}")
                index = text.index(after: escapedIndex)
            case "u":
                var unicodeIndex = text.index(after: escapedIndex)
                var scalarValue = 0
                var digitCount = 0
                while digitCount < 4,
                      unicodeIndex < text.endIndex,
                      let digitValue = hexValue(of: text[unicodeIndex]) {
                    scalarValue = scalarValue * 16 + digitValue
                    digitCount += 1
                    unicodeIndex = text.index(after: unicodeIndex)
                }
                if digitCount == 4, let scalar = UnicodeScalar(scalarValue) {
                    result.unicodeScalars.append(scalar)
                    index = unicodeIndex
                } else {
                    result.append(escaped)
                    index = text.index(after: escapedIndex)
                }
            default:
                result.append(escaped)
                index = text.index(after: escapedIndex)
            }
        }

        return result
    }

    /**
     Detects Java `.properties` key/value whitespace.

     - Parameter character: Character to test.
     - Returns: `true` for space, tab, or form-feed.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func isPropertyWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{000C}"
    }

    /**
     Checks whether a logical line should continue into the next physical line.

     - Parameter text: Current accumulated line.
     - Returns: `true` when the line ends in an odd number of backslashes.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func hasOddTrailingBackslashes(_ text: String) -> Bool {
        var count = 0
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous] == "\\" else { break }
            count += 1
            index = previous
        }
        return count % 2 == 1
    }

    /**
     Converts one hexadecimal character to its integer value.

     - Parameter character: Candidate hexadecimal digit.
     - Returns: Integer value for `0...9`, `a...f`, and `A...F`, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func hexValue(of character: Character) -> Int? {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return nil
        }

        switch value {
        case 48...57:
            return Int(value - 48)
        case 65...70:
            return Int(value - 55)
        case 97...102:
            return Int(value - 87)
        default:
            return nil
        }
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
            isDateBased: hasDateBasedPrefix(readings[1] ?? ""),
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
