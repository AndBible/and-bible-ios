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
    /// Explicit signed-Int32 property keys retained in ascending order.
    public let dayNumbers: [Int]
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
       - dayNumbers: Explicit Android integer property keys encoded by the plan.
       - isDateBased: Whether readings use Android's date-prefixed syntax.
       - readingsForDay: Closure returning the readings string for a 1-based day number.
     */
    public init(
        code: String,
        name: String,
        description: String,
        dayNumbers: [Int],
        isDateBased: Bool = false,
        readingsForDay: @escaping @Sendable (Int) -> String
    ) {
        self.code = code
        self.name = name
        self.description = description
        self.dayNumbers = Array(Set(dayNumbers)).sorted()
        self.totalDays = max(self.dayNumbers.max() ?? 0, 0)
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

/** Errors raised while importing an Android-compatible custom reading-plan definition. */
public enum ReadingPlanImportError: Error, Equatable {
    /// The selected filename cannot become Android's stable plan code.
    case invalidFileName

    /// The selected properties text contains no numeric day assignments.
    case invalidProperties

    /// A custom filename would override one of Android's bundled reading-plan identities.
    case bundledPlanCodeCollision

    /// Existing definition bytes can only be changed together with their persisted plan graph.
    case coordinatedMutationRequired

    /// The destination definition could not be persisted.
    case writeFailed
}

/** Fail-visible local reading-plan mutation errors. */
public enum ReadingPlanMutationError: Error, Equatable {
    /// A requested Android current-day offset cannot be represented by the supplied calendar.
    case unrepresentableStartDate
}

/** Fail-visible errors raised while loading reading-plan definition metadata. */
public enum ReadingPlanDefinitionError: Error, Equatable, LocalizedError, Sendable {
    /// No valid definition can be loaded for the requested stable plan code.
    case unavailable(planCode: String)

    /// Android-shared generic description suitable for the daily-reading failure alert.
    public var errorDescription: String? {
        String(localized: "error_occurred", defaultValue: "An error has occurred")
    }
}

/**
 Provides Android-compatible reading plan templates and plan lifecycle helpers.

 The catalog mirrors Android's `ReadingPlanTextFileDao`: bundled `.properties` plans are listed
 first, followed by unique user files from `jsword/readingplan`, followed by unique add-on-provided
 plans declared through `AndBibleProvidesReadingPlan`.

 Day numbering is intentionally 1-based for plan templates, day rows, and the persisted
 `ReadingPlan.currentDay` field, matching Android's Room schema default.
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

    /** Selected readable definition and the parsed day content that establishes its validity. */
    private struct LoadedPlanDefinition {
        /// Source whose metadata and content won Android's priority order.
        let source: PlanSource

        /// Decoded source text retained for structural metadata parsing.
        let propertiesText: String

        /// UTF-8 reader view used only for Android's leading-comment display metadata.
        let metadataText: String

        /// Numeric day assignments parsed from the selected source.
        let readings: [Int: String]
    }

    /** Two Android decoding views over one exact bounded properties payload. */
    private struct PropertiesPayload {
        /// `Properties.load(InputStream)` byte-to-character interpretation.
        let valuesText: String

        /// Kotlin `bufferedReader()` interpretation used for leading comments.
        let metadataText: String
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
     Returns whether a code belongs to Android's bundled reading-plan catalog.

     - Parameter code: Exact filename-style reading-plan identity.
     - Returns: `true` only for definitions shipped in the application bundle.
     - Side effects: none.
     - Failure modes: This lookup cannot fail.
     */
    static func isBundledPlanCode(_ code: String) -> Bool {
        bundledPlanDefinitions.contains { $0.code == code }
    }

    /**
     Builds only templates backed by definitions bundled on both supported platforms.

     Manifestless Android sync archives carry no content identity for custom or add-on plans. Their
     rows must therefore resolve against this catalog rather than files already present on the iOS
     recipient, which could share a code while describing a different schedule.

     - Returns: Valid bundled templates in Android's catalog order.
     - Side effects: Reads bundled `.properties` resources.
     - Failure modes: Missing or malformed bundled resources are omitted consistently with `catalog`.
     */
    static func bundledTemplates() -> [ReadingPlanTemplate] {
        bundledPlanDefinitions.compactMap { definition in
            template(
                code: definition.code,
                bundledDefinition: definition,
                userPlanFile: nil,
                addonProvider: nil
            )
        }
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

    /**
     Loads the optional raw `Versification` value used by Android for one reading plan.

     Definition content uses the same source and validity rules as catalog templates: a readable
     add-on file wins over a user file, which wins over the bundled definition. A readable selected
     source with no numeric day assignments is invalid and does not fall through; an unreadable
     candidate does fall through to the next source. For add-ons, module `Versification` metadata
     overrides the selected file property, matching Android's `ReadingPlanTextFileDao`.

     - Parameters:
       - code: Stable plan code whose definition metadata should be loaded.
       - userPlanDirectory: Directory containing Android-compatible user `.properties` plans.
       - modulePath: SWORD module root containing add-on module configs and provider files.
     - Returns: The decoded Java-properties value, or `nil` when the selected valid definition does
       not declare `Versification`.
     - Side effects: Reads user-plan directory metadata, SWORD configs, and local definition files.
     - Throws: `ReadingPlanDefinitionError.unavailable(planCode:)` when no valid definition can be
       loaded for `code`.
     - Note: The returned value is not trimmed, defaulted, or mapped to a supported canon.
     */
    public static func versificationProperty(
        forPlanCode code: String,
        userPlanDirectory: URL? = ReadingPlanService.defaultUserReadingPlanDirectory(),
        modulePath: String = SwordManager.defaultModulePath()
    ) throws -> String? {
        let userPlansByCode = Dictionary(
            userPlanFiles(in: userPlanDirectory).map { ($0.code, $0.url) }
        ) { first, _ in first }
        let providersByCode = Dictionary(
            SwordManager.readingPlanProviders(modulePath: modulePath).map { ($0.planCode, $0) }
        ) { _, last in last }

        guard let definition = loadedPlanDefinition(
            code: code,
            userPlanFile: userPlansByCode[code],
            addonProvider: providersByCode[code]
        ) else {
            throw ReadingPlanDefinitionError.unavailable(planCode: code)
        }

        if case .addon(let provider) = definition.source,
           let providerVersification = provider.versification {
            return providerVersification
        }
        return propertyValue(named: "Versification", in: definition.propertiesText)
    }

    // MARK: - .properties File Parser

    /**
     Loads one valid definition using Android's content-source priority.

     Source readability is evaluated before falling through from add-on to user to bundle. Once a
     source decodes, its parsed day assignments determine validity; malformed readable content does
     not fall through because catalog template loading observes that same selected source.

     - Parameters:
       - code: Stable plan code used for bundled-resource lookup.
       - userPlanFile: Matching user file, when discovered.
       - addonProvider: Matching add-on provider, when discovered.
     - Returns: Selected source, decoded text, and numeric day assignments, or `nil` when the
       selected source is missing or invalid.
     - Side effects: Reads candidate definition files in priority order until one decodes.
     - Failure modes: Missing, undecodable, or dayless selected definitions return `nil`.
     */
    private static func loadedPlanDefinition(
        code: String,
        userPlanFile: URL?,
        addonProvider: SwordReadingPlanProvider?
    ) -> LoadedPlanDefinition? {
        let source: PlanSource
        let selectedPayload: PropertiesPayload

        if let addonProvider,
           let payload = propertiesPayload(from: addonProvider.fileURL) {
            source = .addon(addonProvider)
            selectedPayload = payload
        } else if let userPlanFile,
                  let payload = propertiesPayload(from: userPlanFile) {
            source = .userFile(userPlanFile)
            selectedPayload = payload
        } else if let payload = bundledPropertiesPayload(code: code) {
            source = .bundled
            selectedPayload = payload
        } else {
            return nil
        }

        let readings = parseProperties(selectedPayload.valuesText)
        guard !readings.isEmpty else { return nil }
        return LoadedPlanDefinition(
            source: source,
            propertiesText: selectedPayload.valuesText,
            metadataText: selectedPayload.metadataText,
            readings: readings
        )
    }

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
     - Side effects: Reads candidate definition files in priority order until one decodes.
     - Failure modes: Missing or malformed selected sources return `nil`.
     */
    private static func template(
        code: String,
        bundledDefinition: BundledPlanDefinition?,
        userPlanFile: URL?,
        addonProvider: SwordReadingPlanProvider?
    ) -> ReadingPlanTemplate? {
        guard let definition = loadedPlanDefinition(
            code: code,
            userPlanFile: userPlanFile,
            addonProvider: addonProvider
        ) else { return nil }

        let display = displayMetadata(
            code: code,
            bundledDefinition: bundledDefinition,
            source: definition.source,
            propertiesText: definition.metadataText
        )
        let isDateBased = isDateBased(
            source: definition.source,
            firstDayReadings: definition.readings[1] ?? ""
        )
        let readings = definition.readings

        return ReadingPlanTemplate(
            code: code,
            name: display.name,
            description: display.description,
            dayNumbers: readings.keys.sorted(),
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
                options: []
              ) else {
            return []
        }

        let candidates = urls
            .filter { $0.lastPathComponent.hasSuffix(".properties") }
            .compactMap { url -> UserPlanFile? in
                let code = url.lastPathComponent.replacingOccurrences(
                    of: ".properties",
                    with: ""
                )
                guard !code.isEmpty else { return nil }
                return UserPlanFile(code: code, url: url)
            }
        let collisionKeys = Dictionary(grouping: candidates) {
            $0.code.precomposedStringWithCanonicalMapping.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
        }.filter { $0.value.count > 1 }.keys
        return candidates.filter { candidate in
            !collisionKeys.contains(
                candidate.code.precomposedStringWithCanonicalMapping.lowercased(
                    with: Locale(identifier: "en_US_POSIX")
                )
            )
        }
    }

    /**
     Reads a bundled Android plan resource as text.

     - Parameter code: Bundled plan code.
     - Returns: Decoded plan text.
     - Side effects: Reads one bundled resource.
     - Failure modes: Missing or undecodable resources return `nil`.
     */
    private static func bundledPropertiesPayload(code: String) -> PropertiesPayload? {
        guard let url = moduleResourceURL(
            forResource: code,
            withExtension: "properties",
            subdirectories: ["readingplan", "Resources/readingplan"]
        ) else { return nil }

        return propertiesPayload(from: url)
    }

    /**
     Reads one Android `.properties` file using the encodings accepted by local catalog sources.

     - Parameter url: Local plan file URL.
     - Returns: Decoded text.
     - Side effects: Reads `url` from disk.
     - Failure modes: Missing or undecodable files return `nil`.
     */
    private static func propertiesText(from url: URL) -> String? {
        propertiesPayload(from: url)?.valuesText
    }

    /**
     Reads one definition once and exposes Android's distinct values and comment decodings.

     - Parameter url: Local plan definition URL.
     - Returns: Latin-1 property text plus UTF-8 comment text, or nil for unsafe/unreadable files.
     - Side effects: Opens one no-follow descriptor and reads at most the shared definition limit.
     - Failure modes: Symlinks, nonregular files, growth, and oversized files return nil.
     */
    private static func propertiesPayload(from url: URL) -> PropertiesPayload? {
        guard let data = try? RemoteSyncReadingPlanDefinitionStore
            .readBoundedDefinitionData(from: url),
              let valuesText = String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return PropertiesPayload(
            valuesText: valuesText,
            metadataText: String(decoding: data, as: UTF8.self)
        )
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
        for line in physicalPropertiesLines(from: text).prefix(5) {
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
        readings.range(
            of: #"^[A-Za-z]{3}-[0-9]{1,2};"#,
            options: .regularExpression
        ) != nil
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
     Parses Java-properties content into Android's day-to-readings dictionary.

     Numeric keys use Java's decoded key exactly: escaped leading whitespace is significant, while
     unescaped separators and continuation whitespace are handled by `Properties.load` rules.

     - Parameter text: ISO-8859-1-decoded `.properties` content.
     - Returns: Keys accepted by Kotlin's signed 32-bit `String.toIntOrNull()` conversion.
     - Side Effects: none.
     - Failure modes: Nonnumeric or out-of-range keys are ignored, matching Android's `toIntOrNull`.
     */
    public static func parseProperties(_ text: String) -> [Int: String] {
        var readings: [Int: String] = [:]
        for entry in parsedProperties(text) {
            // Skip non-numeric keys (e.g. "Versification=KJV")
            guard let dayNumber = Int32(entry.key).map(Int.init) else { continue }
            readings[dayNumber] = entry.value
        }
        return readings
    }

    /**
     Returns every decoded property key whose complete text has signed ASCII-integer syntax.

     Validation uses this stream before integer conversion so arbitrarily large numeric keys cannot
     disappear through integer overflow before validation.

     - Parameter text: ISO-8859-1-decoded Java-properties content.
     - Returns: Numeric-looking decoded keys in source order, including duplicates.
     - Side Effects: none.
     - Failure modes: Malformed nonnumeric keys are omitted.
     */
    static func numericPropertyKeys(in text: String) -> [String] {
        parsedProperties(text).compactMap { entry in
            let digits: Substring
            if entry.key.first == "+" || entry.key.first == "-" {
                digits = entry.key.dropFirst()
            } else {
                digits = entry.key[...]
            }
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
                return nil
            }
            return entry.key
        }
    }

    /**
     Parses Java-properties entries using the same structural rules as reading assignments.

     - Parameter text: Raw `.properties` content.
     - Returns: Ordered decoded key/value entries; duplicate keys remain ordered for callers to
       apply Java's last-value-wins behavior.
     - Side effects: none.
     - Failure modes: Ignored lines are omitted and malformed escapes follow
       `unescapePropertyText(_:)` recovery behavior.
     */
    private static func parsedProperties(_ text: String) -> [(key: String, value: String)] {
        logicalPropertiesLines(from: text).compactMap { line in
            guard let entry = propertiesEntry(from: line) else { return nil }
            return (
                key: unescapePropertyText(entry.key),
                value: unescapePropertyText(entry.value)
            )
        }
    }

    /**
     Returns the last decoded value for one exact Java-properties key.

     - Parameters:
       - name: Case-sensitive decoded property key.
       - text: Raw `.properties` content.
     - Returns: The final matching value, including significant trailing whitespace, or `nil`.
     - Side effects: none.
     - Failure modes: Malformed escapes use the parser's documented literal recovery behavior.
     */
    private static func propertyValue(named name: String, in text: String) -> String? {
        parsedProperties(text).last { $0.key == name }?.value
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
        var isContinuation = false

        for physicalLine in physicalPropertiesLines(from: text) {
            if isContinuation {
                current += physicalLine.drop(while: isPropertyWhitespace)
            } else {
                current = physicalLine
            }

            if hasOddTrailingBackslashes(current) {
                current.removeLast()
                isContinuation = true
                continue
            }

            logicalLines.append(current)
            current = ""
            isContinuation = false
        }

        if !current.isEmpty {
            logicalLines.append(current)
        }

        return logicalLines
    }

    /**
     Splits Java-properties text only at CR, LF, or CRLF physical line boundaries.

     Foundation's broad newline character set also treats Latin-1 NEL as a separator, while
     `Properties.load(InputStream)` treats byte `0x85` as ordinary value data.

     - Parameter text: ISO-8859-1-decoded properties content.
     - Returns: Physical lines, retaining a final empty line after a terminal line separator.
     - Side Effects: none.
     - Failure modes: none.
     */
    private static func physicalPropertiesLines(from text: String) -> [String] {
        let scalars = text.unicodeScalars
        var lines: [String] = []
        var lineStart = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar.value == 0x0d || scalar.value == 0x0a else {
                index = scalars.index(after: index)
                continue
            }
            lines.append(String(scalars[lineStart..<index]))
            let next = scalars.index(after: index)
            if scalar.value == 0x0d,
               next < scalars.endIndex,
               scalars[next].value == 0x0a {
                index = scalars.index(after: next)
            } else {
                index = next
            }
            lineStart = index
        }
        lines.append(String(scalars[lineStart...]))
        return lines
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
                guard let decoded = decodedUnicodeEscape(
                    in: text,
                    digitsStart: text.index(after: escapedIndex)
                ) else {
                    result.append(escaped)
                    index = text.index(after: escapedIndex)
                    continue
                }
                let firstUnit = decoded.unit
                if (0xD800...0xDBFF).contains(firstUnit),
                   decoded.endIndex < text.endIndex,
                   text[decoded.endIndex] == "\\" {
                    let nextU = text.index(after: decoded.endIndex)
                    if nextU < text.endIndex,
                       text[nextU] == "u",
                       let low = decodedUnicodeEscape(
                           in: text,
                           digitsStart: text.index(after: nextU)
                       ),
                       (0xDC00...0xDFFF).contains(low.unit) {
                        let value = 0x10000
                            + ((firstUnit - 0xD800) << 10)
                            + (low.unit - 0xDC00)
                        if let scalar = UnicodeScalar(value) {
                            result.unicodeScalars.append(scalar)
                            index = low.endIndex
                            continue
                        }
                    }
                }
                if let scalar = UnicodeScalar(firstUnit) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result.unicodeScalars.append("\u{FFFD}")
                }
                index = decoded.endIndex
            default:
                result.append(escaped)
                index = text.index(after: escapedIndex)
            }
        }

        return result
    }

    /** Decodes exactly four hexadecimal UTF-16 code-unit digits after one Java `\u` marker. */
    private static func decodedUnicodeEscape(
        in text: String,
        digitsStart: String.Index
    ) -> (unit: Int, endIndex: String.Index)? {
        var index = digitsStart
        var value = 0
        for _ in 0..<4 {
            guard index < text.endIndex, let digit = hexValue(of: text[index]) else { return nil }
            value = value * 16 + digit
            index = text.index(after: index)
        }
        return (value, index)
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
     Parses a custom reading plan without persisting a definition file.

     This compatibility overload now derives a deterministic Android-compatible code from `name`;
     UI imports use the filename-aware overload below so restart and restore can rediscover the
     exact definition.

     - Parameters:
       - name: User-visible plan name and stable-code source for compatibility callers.
       - propertiesText: Raw `.properties` file content using Android plan syntax.
     - Returns: Parsed template when at least one numeric day exists, otherwise `nil`.
     - Side effects: none.
     - Failure modes: Invalid names or properties return `nil`.
     */
    public static func importCustomPlan(name: String, propertiesText: String) -> ReadingPlanTemplate? {
        let readings = parseProperties(propertiesText)
        guard !readings.isEmpty else { return nil }

        let totalDays = readings.keys.max() ?? 0
        let code = stableCustomPlanCode(from: name)
        guard !code.isEmpty else { return nil }

        return ReadingPlanTemplate(
            code: code,
            name: name,
            description: "Custom imported reading plan (\(totalDays) days).",
            dayNumbers: readings.keys.sorted(),
            isDateBased: hasDateBasedPrefix(readings[1] ?? ""),
            readingsForDay: { day in
                readings[day] ?? ""
            }
        )
    }

    /**
     Persists and imports one custom Android `.properties` reading plan.

     Android defines custom identity as the exact filename without `.properties`. iOS writes the
     original text to the equivalent `jsword/readingplan` folder before rebuilding the catalog, so
     the same stable code survives restart, backup restore, and sync replay whenever the Android
     definition file is present.

     - Parameters:
       - fileName: Source filename including Android's exact lowercase `.properties` extension.
       - propertiesText: Raw Java-properties content.
       - userPlanDirectory: Android-equivalent user definition directory.
     - Returns: Rediscovered persisted template.
     - Side effects: Creates the destination directory and atomically writes one `.properties` file.
     - Failure modes:
       - throws `ReadingPlanImportError.invalidFileName` for empty/path-like codes
       - throws `ReadingPlanImportError.invalidProperties` when no numeric day is present
       - throws `ReadingPlanImportError.writeFailed` when persistence or rediscovery fails
     */
    public static func importCustomPlan(
        fileName: String,
        propertiesText: String,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) throws -> ReadingPlanTemplate {
        try importCustomPlan(
            fileName: fileName,
            propertiesData: Data(propertiesText.utf8),
            userPlanDirectory: userPlanDirectory
        )
    }

    /**
     Persists an unreferenced custom definition without transcoding its Java-properties bytes.

     This compatibility entry point permits a new file or an idempotent write of identical bytes.
     Replacing different bytes requires `importAndStartCustomPlan`, which updates any existing plan
     graph and progress in the same durable publication.

     - Parameters:
       - fileName: Exact source filename ending in lowercase `.properties`.
       - propertiesData: Original bytes interpreted by Android as ISO-8859-1.
       - userPlanDirectory: Android-equivalent user definition directory.
     - Returns: Template parsed from the exact persisted bytes.
     - Side effects: May atomically create one unreferenced definition file.
     - Throws: Validation, collision, coordinated-mutation, or filesystem errors.
     */
    public static func importCustomPlan(
        fileName: String,
        propertiesData: Data,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) throws -> ReadingPlanTemplate {
        let store = RemoteSyncReadingPlanDefinitionStore(userPlanDirectory: userPlanDirectory)
        let definition = try store.validatedDefinition(
            fileName: fileName,
            propertiesData: propertiesData
        )
        try store.installUnreferencedDefinition(definition)
        return try customTemplate(for: definition)
    }

    /**
     Reads one selected custom definition without allocating beyond the accepted payload bound.

     The security-scoped access lifetime remains owned by the UI caller. This helper verifies the
     selected item is a regular nonsymlink file, rejects an oversized metadata length before reading,
     then caps the actual read at one byte beyond the shared definition limit to catch file growth.

     - Parameter url: Security-accessible local file selected for import.
     - Returns: Exact source bytes without text decoding or newline normalization.
     - Side effects: Opens and reads the selected file, then closes its handle.
     - Throws: Filename, filesystem, or `definitionTooLarge` errors before import publication.
     */
    public static func readCustomPlanDefinitionData(from url: URL) throws -> Data {
        do {
            return try RemoteSyncReadingPlanDefinitionStore.readBoundedDefinitionData(from: url)
        } catch RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(_) {
            throw ReadingPlanImportError.invalidFileName
        }
    }

    /**
     Imports or edits a custom plan and selects it through one crash-recoverable transaction.

     Exact source bytes are published as one filesystem generation. A changed definition rebuilds
     every persisted day for that code and removes per-reading statuses that no longer describe the
     schedule. The graph, selected-plan preference, sync mutation journal, and definition generation
     commit marker then save together through `SettingsStore.performAtomicBatch`.

     - Parameters:
       - fileName: Exact source filename ending in lowercase `.properties`.
       - propertiesData: Original Java-properties bytes without transcoding.
       - modelContext: Clean SwiftData context containing plans and settings.
       - settingsStore: Settings store bound to `modelContext`.
       - userPlanDirectory: Android-equivalent user definition directory.
     - Returns: Newly created or rebuilt persisted plan selected by its stable code.
     - Side effects: Publishes definition bytes, mutates plan/day/status rows, writes selection and
       mutation-journal settings, and commits once.
     - Throws: Validation, collision, context, journal, filesystem, or persistence failures. A failed
       operation restores the prior definition generation and graph/settings transaction.
     - Important: Callers must not pass a context with unrelated pending changes.
     */
    public static func importAndStartCustomPlan(
        fileName: String,
        propertiesData: Data,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) throws -> ReadingPlan {
        let store = RemoteSyncReadingPlanDefinitionStore(userPlanDirectory: userPlanDirectory)
        let definition = try store.validatedDefinition(
            fileName: fileName,
            propertiesData: propertiesData
        )
        let importedTemplate = try customTemplate(for: definition)

        return try store.withPublishingLocalDefinition(
            definition,
            modelContext: modelContext,
            settingsStore: settingsStore
        ) { definitionChanged in
            let existingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
            let selectedPlan: ReadingPlan
            if let existingPlan = existingPlans.first(where: { $0.planCode == definition.planCode }) {
                selectedPlan = existingPlan
                if definitionChanged {
                    for day in existingPlan.days ?? [] {
                        modelContext.delete(day)
                    }
                    let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
                    for status in try statusStore.allStatusesStrict()
                    where status.planCode == definition.planCode {
                        statusStore.removeStatus(
                            planCode: status.planCode,
                            dayNumber: status.dayNumber
                        )
                    }
                    existingPlan.planName = importedTemplate.name
                    existingPlan.totalDays = importedTemplate.totalDays
                    for dayNumber in importedTemplate.dayNumbers {
                        let day = ReadingPlanDay(
                            dayNumber: dayNumber,
                            readings: importedTemplate.readingsForDay(dayNumber)
                        )
                        day.plan = existingPlan
                        modelContext.insert(day)
                    }
                }
            } else {
                let plan = ReadingPlan(
                    planCode: importedTemplate.code,
                    planName: importedTemplate.name,
                    startDate: Calendar.current.startOfDay(for: Date()),
                    currentDay: 1,
                    totalDays: importedTemplate.totalDays,
                    isActive: true
                )
                modelContext.insert(plan)
                for dayNumber in importedTemplate.dayNumbers {
                    let day = ReadingPlanDay(
                        dayNumber: dayNumber,
                        readings: importedTemplate.readingsForDay(dayNumber)
                    )
                    day.plan = plan
                    modelContext.insert(day)
                }
                selectedPlan = plan
            }

            settingsStore.setString(
                ReadingPlanSelectionStore.settingsKey,
                value: selectedPlan.planCode
            )
            let timestampStore = RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
            if try timestampStore.allMilliseconds()[selectedPlan.id] == nil {
                timestampStore.setMilliseconds(
                    try AndroidTimestamp.milliseconds(from: selectedPlan.startDate),
                    for: selectedPlan.id
                )
            }
            for plan in existingPlans where plan.id != selectedPlan.id {
                plan.isActive = false
            }
            selectedPlan.isActive = true
            modelContext.processPendingChanges()
            try RemoteSyncMutationJournalService(
                readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService(
                    userPlanDirectory: userPlanDirectory
                )
            ).recordLocalChanges(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return selectedPlan
        }
    }

    /**
     Recovers a definition-directory publication interrupted around its graph/settings commit.

     - Parameters:
       - settingsStore: Settings source containing the committed definition-generation marker.
       - userPlanDirectory: Android-equivalent custom definition directory.
     - Side effects: Finalizes a committed generation or restores the prior directory before catalog use.
     - Throws: Durable journal decoding or contradictory filesystem recovery failures.
     */
    public static func recoverCustomPlanDefinitionPublication(
        settingsStore: SettingsStore,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) throws {
        try RemoteSyncReadingPlanDefinitionStore(userPlanDirectory: userPlanDirectory)
            .recoverPendingPublication(settingsStore: settingsStore)
    }

    /**
     Builds a template from one already validated exact-byte custom definition.

     - Parameter definition: Safe filename identity and Java-properties byte payload.
     - Returns: Parsed custom template.
     - Side effects: none.
     - Throws: `ReadingPlanImportError.invalidProperties` when decoding or parsing unexpectedly fails.
     */
    private static func customTemplate(
        for definition: RemoteSyncReadingPlanDefinition
    ) throws -> ReadingPlanTemplate {
        guard let propertiesText = String(data: definition.propertiesData, encoding: .isoLatin1) else {
            throw ReadingPlanImportError.invalidProperties
        }
        let readings = parseProperties(propertiesText)
        guard let totalDays = readings.keys.max(), totalDays > 0 else {
            throw ReadingPlanImportError.invalidProperties
        }
        let metadata = userPlanMetadata(
            from: String(decoding: definition.propertiesData, as: UTF8.self),
            fallbackName: definition.planCode
        )
        return ReadingPlanTemplate(
            code: definition.planCode,
            name: metadata.name,
            description: metadata.description,
            dayNumbers: readings.keys.sorted(),
            isDateBased: hasDateBasedPrefix(readings[1] ?? ""),
            readingsForDay: { day in readings[day] ?? "" }
        )
    }

    /**
     Produces a deterministic compatibility code for callers without a source filename.

     - Parameter name: User-visible imported-plan name.
     - Returns: Trimmed code with path separators and whitespace replaced by underscores.
     - Side effects: none.
     - Failure modes: Empty input returns an empty string.
     */
    private static func stableCustomPlanCode(from name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\\/\s]+"#, with: "_", options: .regularExpression)
    }

    // MARK: - Plan Management

    /**
     Starts a new persisted reading plan from a template.
     - Parameters:
       - template: Template defining sparse Android day keys and daily readings.
       - modelContext: Context used to insert the plan and all child day rows.
       - selectionStore: Android `reading_plan` preference store, when available.
     - Returns: Existing started plan with the same code, or a newly created persisted plan.
     - Side effects: Selects exactly one plan, creating its day graph only on first start.
     - Throws: Plan fetch, timestamp conversion, mutation-journal, settings, or model-save failure.
     - Note: This materializes only explicit signed-Int32 property keys and stores the start date at
       the local day boundary to mirror Android's truncated plan date.
     */
    public static func startPlan(
        template: ReadingPlanTemplate,
        modelContext: ModelContext,
        selectionStore: ReadingPlanSelectionStore? = nil
    ) throws -> ReadingPlan {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        let startDateMilliseconds = try AndroidTimestamp.milliseconds(from: startDate)
        let existingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        if let existingPlan = existingPlans.first(where: { $0.planCode == template.code }) {
            if let selectionStore {
                try selectionStore.select(
                    existingPlan,
                    among: existingPlans,
                    modelContext: modelContext
                )
            } else {
                for plan in existingPlans {
                    plan.isActive = plan.id == existingPlan.id
                }
                try RemoteSyncMutationJournalService.savePendingGraphChanges(
                    for: .readingPlans,
                    modelContext: modelContext
                )
            }
            return existingPlan
        }
        for existingPlan in existingPlans {
            existingPlan.isActive = false
        }
        let plan = ReadingPlan(
            planCode: template.code,
            planName: template.name,
            startDate: startDate,
            currentDay: 1,
            totalDays: template.totalDays,
            isActive: true
        )
        modelContext.insert(plan)

        for day in template.dayNumbers {
            let planDay = ReadingPlanDay(
                dayNumber: day,
                readings: template.readingsForDay(day)
            )
            planDay.plan = plan
            modelContext.insert(planDay)
        }

        if let selectionStore {
            try selectionStore.select(
                plan,
                among: existingPlans + [plan],
                modelContext: modelContext,
                startDateMilliseconds: startDateMilliseconds
            )
        } else {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .readingPlans,
                modelContext: modelContext
            )
        }
        return plan
    }

    /**
     Rebases a non-date plan so the supplied 1-based day number is treated as today's current day.

     - Parameters:
       - dayNumber: Desired Android signed-Int32 plan day. Values below one read back as day one.
       - plan: Persisted plan to mutate.
       - modelContext: SwiftData context used to save the plan and day-row mutations.
       - progressStore: Android status store used to discard rows that become implicit history.
       - now: Clock value used to derive today's date and completion timestamps.
       - calendar: Calendar used to normalize the local start date.
     - Side effects: Updates `plan.startDate`, `plan.currentDay`, marks all earlier day rows
       completed, refreshes the active flag, and journals the mutation atomically.
     - Throws: Status corruption, an unrepresentable calendar offset, timestamp conversion,
       mutation-journal, settings, or model-save failure.
     - Note: The selected day and later days are not rewritten, matching Android's current-day
       action which preserves existing status rows outside the prior-day catch-up range.
     */
    public static func setCurrentDay(
        _ dayNumber: Int,
        for plan: ReadingPlan,
        modelContext: ModelContext,
        progressStore: ReadingPlanProgressStore? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard !isDateBased(plan) else { return }
        guard Int32(exactly: dayNumber) != nil else { return }
        let effectiveDay = max(dayNumber, 1)
        let today = calendar.startOfDay(for: now)
        guard let rebasedStartDate = calendar.date(
            byAdding: .day,
            value: -(effectiveDay - 1),
            to: today
        ) else {
            throw ReadingPlanMutationError.unrepresentableStartDate
        }
        let mutateGraph = {
            plan.startDate = rebasedStartDate
            plan.currentDay = dayNumber
            for day in plan.days ?? [] where day.dayNumber < effectiveDay {
                day.isCompleted = true
                if day.completedDate == nil {
                    day.completedDate = now
                }
            }
            plan.isActive = plan.days?.allSatisfy(\.isCompleted) != true
        }

        if let progressStore {
            try progressStore.performMutation { settingsStore in
                mutateGraph()
                try progressStore.removeStatusesStaged(
                    planCode: plan.planCode,
                    before: effectiveDay
                )
                RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
                    .setMilliseconds(
                        try AndroidTimestamp.milliseconds(from: rebasedStartDate),
                        for: plan.id
                    )
            }
        } else {
            mutateGraph()
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .readingPlans,
                modelContext: modelContext
            )
        }
    }

    /**
     Sets a non-date plan's start date without changing Android's persisted current-day pointer.

     - Parameters:
       - startDate: New date anchor. The date is normalized to the current calendar's start of day
         and capped at today to match Android's start-date picker.
       - plan: Persisted plan to mutate.
       - modelContext: SwiftData context used to save the plan mutation.
       - now: Clock value used to cap future dates.
       - calendar: Calendar used to normalize local days.
     - Side effects: Updates `plan.startDate`, preserves exact milliseconds when a settings store is
       supplied, and journals the mutation.
     - Throws: Timestamp conversion, mutation-journal, settings, or model-save failure.
     - Note: Day completion statuses are intentionally left untouched so changing the date does not
       rewrite user-authored reading progress.
     */
    public static func setStartDate(
        _ startDate: Date,
        for plan: ReadingPlan,
        modelContext: ModelContext,
        settingsStore: SettingsStore? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        guard !isDateBased(plan) else { return }
        let today = calendar.startOfDay(for: now)
        let requestedStart = calendar.startOfDay(for: startDate)
        let normalizedStart = min(requestedStart, today)
        if let settingsStore {
            try settingsStore.performJournaledSave(in: modelContext) {
                plan.startDate = normalizedStart
                RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
                    .setMilliseconds(
                        try AndroidTimestamp.milliseconds(from: normalizedStart),
                        for: plan.id
                    )
                modelContext.processPendingChanges()
                try RemoteSyncMutationJournalService().recordLocalChanges(
                    for: .readingPlans,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }
        } else {
            plan.startDate = normalizedStart
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .readingPlans,
                modelContext: modelContext
            )
        }
    }

    /**
     Deletes one persisted reading plan and its cascaded day rows.

     - Parameters:
       - plan: Persisted plan graph to remove.
       - modelContext: SwiftData context used to delete and save the graph.
       - progressStore: Typed Android status store used to remove status rows.
       - selectionStore: Android selected-plan preference store.
     - Side effects: Deletes the plan graph, statuses, selection, timestamp sidecar, and records the
       local mutation journal through one available settings transaction.
     - Throws: Fetch, status corruption, mutation-journal, settings, or model-save failure.
     */
    public static func resetPlan(
        _ plan: ReadingPlan,
        modelContext: ModelContext,
        progressStore: ReadingPlanProgressStore? = nil,
        selectionStore: ReadingPlanSelectionStore? = nil
    ) throws {
        let remainingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
            .filter { $0.id != plan.id }
        if let progressStore {
            try progressStore.performMutation { settingsStore in
                try resetPlanStaged(
                    plan,
                    remainingPlans: remainingPlans,
                    progressStore: progressStore,
                    settingsStore: settingsStore,
                    modelContext: modelContext
                )
            }
        } else if let selectionStore {
            modelContext.delete(plan)
            try selectionStore.clearIfSelected(
                planCode: plan.planCode,
                among: remainingPlans,
                modelContext: modelContext,
                planID: plan.id
            )
        } else {
            modelContext.delete(plan)
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .readingPlans,
                modelContext: modelContext
            )
        }
    }

    /** Stages one complete plan reset inside an existing progress/settings transaction. */
    private static func resetPlanStaged(
        _ plan: ReadingPlan,
        remainingPlans: [ReadingPlan],
        progressStore: ReadingPlanProgressStore,
        settingsStore: SettingsStore,
        modelContext: ModelContext
    ) throws {
        try progressStore.removeStatusesStaged(planCode: plan.planCode)
        if settingsStore.getString(ReadingPlanSelectionStore.settingsKey) == plan.planCode {
            settingsStore.remove(ReadingPlanSelectionStore.settingsKey)
        }
        RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
            .removeMilliseconds(for: plan.id)
        for remainingPlan in remainingPlans where remainingPlan.planCode == plan.planCode {
            remainingPlan.isActive = false
        }
        modelContext.delete(plan)
    }

    /**
     Applies Android's enabled `Done` transition to one all-read plan day.

     Current non-date days become implicit history by advancing `currentDay`; date-plan `Done`
     retains the explicit status while the date-derived pointer remains unchanged because Android
     deliberately skips historic-status deletion for date plans.
     Finishing the final current day resets the plan graph and selected preference, exactly as
     Android does. Viewing another completed day advances only the displayed day and does not
     rewrite the plan pointer.

     - Parameters:
       - day: Displayed day whose readings must all be marked read.
       - plan: Parent persisted plan.
       - modelContext: Context owning the plan graph.
       - progressStore: Android per-reading status store.
       - selectionStore: Android selected-plan preference store.
       - now: Clock used for due-day decisions.
       - calendar: Calendar used for local date comparisons.
     - Returns: Next due day number, or `nil` when Android would dismiss the daily-reading screen.
     - Side effects: May delete historic status rows, advance `currentDay`, or reset the plan.
     - Throws: Status corruption, fetch, mutation-journal, settings, or model-save failure. An
       incomplete day performs no mutation and returns its own day number.
     */
    public static func finishDay(
        _ day: ReadingPlanDay,
        in plan: ReadingPlan,
        modelContext: ModelContext,
        progressStore: ReadingPlanProgressStore,
        selectionStore: ReadingPlanSelectionStore,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Int? {
        _ = selectionStore
        return try progressStore.performMutation { settingsStore in
            func stageReset() throws {
                let remainingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
                    .filter { $0.id != plan.id }
                try resetPlanStaged(
                    plan,
                    remainingPlans: remainingPlans,
                    progressStore: progressStore,
                    settingsStore: settingsStore,
                    modelContext: modelContext
                )
            }

            let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
            guard try progressStore.status(for: day, in: plan).isAllRead(
                readingCount: assignment.readings.count
            ) else {
                return day.dayNumber
            }

            let currentDay = expectedDay(for: plan, asOf: now, calendar: calendar)
            guard day.dayNumber == currentDay else {
                guard let nextDay = (plan.days ?? [])
                    .map(\.dayNumber)
                    .filter({ $0 > day.dayNumber })
                    .min() else {
                    return nil
                }
                return isDayDue(
                    nextDay,
                    in: plan,
                    asOf: now,
                    calendar: calendar
                ) ? nextDay : nil
            }

            if day.dayNumber >= plan.totalDays {
                try stageReset()
                return nil
            }

            if !isDateBased(plan) {
                let nextStoredDay = (plan.days ?? [])
                    .map(\.dayNumber)
                    .filter { $0 > day.dayNumber }
                    .min() ?? day.dayNumber + 1
                try progressStore.removeStatusesStaged(
                    planCode: plan.planCode,
                    before: nextStoredDay
                )
                plan.currentDay = nextStoredDay
                for candidate in plan.days ?? [] where candidate.dayNumber < plan.currentDay {
                    candidate.isCompleted = true
                    candidate.completedDate = candidate.completedDate ?? now
                }
            }

            let laterDays = (plan.days ?? [])
                .filter { $0.dayNumber > day.dayNumber }
                .sorted { $0.dayNumber < $1.dayNumber }
            for candidate in laterDays {
                let nextDay = candidate.dayNumber
                guard isDayDue(nextDay, in: plan, asOf: now, calendar: calendar) else {
                    return nil
                }
                let candidateAssignment = ReadingPlanDayAssignment(rawValue: candidate.readings)
                if !candidateAssignment.readings.isEmpty {
                    return nextDay
                }
                if nextDay >= plan.totalDays {
                    try stageReset()
                    return nil
                }
                if !isDateBased(plan) {
                    plan.currentDay = laterDays.first { $0.dayNumber > nextDay }?.dayNumber
                        ?? nextDay + 1
                }
            }
            return nil
        }
    }

    /**
     Calculates which 1-based day the user should be on based on normalized calendar dates.
     - Parameter plan: Persisted reading plan.
     - Parameter now: Clock value used when comparing the plan start date to today.
     - Returns: Date-selected day or Android's floor-only current-day value.
     */
    public static func expectedDay(
        for plan: ReadingPlan,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let orderedDays = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        if isDateBased(plan) {
            let today = calendar.startOfDay(for: now)
            return orderedDays.first { day in
                ReadingPlanDayAssignment(rawValue: day.readings)
                    .scheduledDate(inYearContaining: now, calendar: calendar)
                    .map { calendar.isDate($0, inSameDayAs: today) } == true
            }?.dayNumber ?? 1
        }
        return max(plan.currentDay, 1)
    }

    /**
     Detects whether a persisted plan uses Android's calendar-date semantics.

     - Parameter plan: Persisted plan whose first day carries the definition syntax.
     - Returns: `true` when the first day starts with Android's `MMM-d;` date prefix.
     - Side effects: none.
     - Failure modes: Missing day rows return `false`.
     */
    public static func isDateBased(_ plan: ReadingPlan) -> Bool {
        guard let firstDay = plan.days?.first(where: { $0.dayNumber == 1 }) else {
            return false
        }
        return hasDateBasedPrefix(firstDay.readings)
    }

    /**
     Determines whether Android would continue to one plan day as already due.

     Android derives this gate from elapsed local days since the plan's stored start date for both
     ordinal and date-based plans. Date tokens choose the initially displayed day; they do not make
     every earlier calendar token part of a catch-up queue for a plan started midyear.

     - Parameters:
       - dayNumber: Candidate one-based day.
       - plan: Parent plan.
       - now: Current clock value.
       - calendar: Local calendar used for date boundaries.
     - Returns: `true` when the candidate is not in the future.
     - Side effects: none.
     - Failure modes: Calendar arithmetic failures treat the start day as day one.
     */
    private static func isDayDue(
        _ dayNumber: Int,
        in plan: ReadingPlan,
        asOf now: Date,
        calendar: Calendar
    ) -> Bool {
        let start = calendar.startOfDay(for: plan.startDate)
        let today = calendar.startOfDay(for: now)
        let dueDay = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        return dueDay >= dayNumber
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
