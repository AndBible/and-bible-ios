// BackupService.swift — Data export/import

import Foundation
import SwiftData

/// Full JSON backup payload for app data export/import.
///
/// Version `1` currently contains:
/// - Bible bookmarks and their label assignments
/// - user-visible labels
/// - reading plans and their completed day numbers
/// - StudyPad text entries
public struct AppBackup: Codable {
    /// Backup schema version.
    public var version: Int = 1
    /// Export timestamp as seconds since 1970.
    public var timestamp: Double
    /// Exporting platform identifier.
    public var platform: String = "iOS"
    /// Exported Bible bookmarks.
    public var bookmarks: [BookmarkBackup]
    /// Exported user labels.
    public var labels: [LabelBackup]
    /// Exported reading plans.
    public var readingPlans: [ReadingPlanBackup]
    /// Exported StudyPad entries.
    public var studyPadEntries: [StudyPadEntryBackup]
}

/// Codable representation of a Bible bookmark inside a full JSON backup.
public struct BookmarkBackup: Codable {
    /// Bookmark UUID string.
    public var id: String
    /// Start KJVA ordinal used by the bookmark.
    public var kjvOrdinalStart: Int
    /// End KJVA ordinal used by the bookmark.
    public var kjvOrdinalEnd: Int
    /// Start ordinal in the original versification.
    public var ordinalStart: Int
    /// End ordinal in the original versification.
    public var ordinalEnd: Int
    /// Original versification identifier.
    public var v11n: String
    /// Optional book snapshot used to avoid cross-book collisions.
    public var book: String?
    /// Creation timestamp as seconds since 1970.
    public var createdAt: Double
    /// Last-update timestamp as seconds since 1970.
    public var lastUpdatedOn: Double
    /// Whether the bookmark covers a whole verse.
    public var wholeVerse: Bool
    /// Optional primary label UUID string.
    public var primaryLabelId: String?
    /// Optional detached note text.
    public var notes: String?
    /// Label UUID strings associated with the bookmark.
    public var labelIds: [String]
}

/// Codable representation of a user-visible label inside a full JSON backup.
public struct LabelBackup: Codable {
    /// Label UUID string.
    public var id: String
    /// User-visible label name.
    public var name: String
    /// Android-style ARGB color payload.
    public var color: Int
    /// Marker-style highlight flag.
    public var markerStyle: Bool
    /// Underline-style highlight flag.
    public var underlineStyle: Bool
    /// Favourite/quick-access flag.
    public var favourite: Bool
}

/// Codable representation of a reading plan inside a full JSON backup.
public struct ReadingPlanBackup: Codable {
    /// Reading-plan UUID string.
    public var id: String
    /// Template/import code.
    public var planCode: String
    /// User-visible plan name.
    public var planName: String
    /// Start date as seconds since 1970.
    public var startDate: Double
    /// Persisted current-day pointer.
    public var currentDay: Int
    /// Total number of days in the plan.
    public var totalDays: Int
    /// Whether the plan is active.
    public var isActive: Bool
    /// 1-based completed day numbers.
    public var completedDays: [Int]
}

/// Codable representation of a StudyPad text entry inside a full JSON backup.
public struct StudyPadEntryBackup: Codable {
    /// StudyPad entry UUID string.
    public var id: String
    /// Owning label UUID string, when present.
    public var labelId: String?
    /// Display order within the StudyPad.
    public var orderNumber: Int
    /// Nesting depth within the StudyPad.
    public var indentLevel: Int
    /// Detached text payload.
    public var text: String
}

/// Manages export and import of app data.
///
/// Export shapes:
/// - CSV: Bible bookmarks only, with quoted note text for spreadsheet-friendly interchange
/// - JSON: full app backup including labels, reading plans, and StudyPad entries
///
/// Import order matters because later records depend on earlier ones:
/// 1. labels
/// 2. Bible bookmarks and label junctions
/// 3. StudyPad entries
/// 4. reading plans and reconstructed day rows
///
/// Error handling is intentionally soft-fail:
/// - export methods return `nil` on encoding failures
/// - import methods return the count of successfully inserted items and skip malformed rows
@Observable
public final class BackupService {
    private let modelContext: ModelContext

    /// Creates a backup service bound to the caller's SwiftData context.
    /// - Parameter modelContext: Context used for all export/import reads and writes.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CSV Export (Bookmarks)

    /// Exports Bible bookmarks as UTF-8 CSV data.
    ///
    /// Current column order:
    /// `id,kjvOrdinalStart,kjvOrdinalEnd,v11n,createdAt,wholeVerse,primaryLabelId,notes`
    ///
    /// Notes are wrapped in quotes and embedded quotes are doubled for CSV compatibility.
    ///
    /// - Returns: CSV data on success, otherwise `nil`.
    public func exportBookmarksCSV() -> Data? {
        let store = BookmarkStore(modelContext: modelContext)
        let bookmarks = store.bibleBookmarks()

        var csv = "id,kjvOrdinalStart,kjvOrdinalEnd,v11n,createdAt,wholeVerse,primaryLabelId,notes\n"

        for bm in bookmarks {
            let noteText = bm.notes?.notes ?? ""
            let escapedNotes = noteText.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(bm.id),\(bm.kjvOrdinalStart),\(bm.kjvOrdinalEnd),\(bm.v11n),"
            csv += "\(bm.createdAt.timeIntervalSince1970),\(bm.wholeVerse),"
            csv += "\(bm.primaryLabelId?.uuidString ?? ""),\"\(escapedNotes)\"\n"
        }

        return csv.data(using: .utf8)
    }

    // MARK: - Full JSON Backup

    /// Exports a full JSON backup of bookmarks, labels, reading plans, and StudyPad entries.
    /// - Returns: Pretty-printed, sorted-key JSON data on success, otherwise `nil`.
    public func exportFullBackup() -> Data? {
        let store = BookmarkStore(modelContext: modelContext)
        let planStore = ReadingPlanStore(modelContext: modelContext)

        // Bookmarks
        let bookmarks = store.bibleBookmarks()
        let bookmarkBackups = bookmarks.map { bm in
            BookmarkBackup(
                id: bm.id.uuidString,
                kjvOrdinalStart: bm.kjvOrdinalStart,
                kjvOrdinalEnd: bm.kjvOrdinalEnd,
                ordinalStart: bm.ordinalStart,
                ordinalEnd: bm.ordinalEnd,
                v11n: bm.v11n,
                book: bm.book,
                createdAt: bm.createdAt.timeIntervalSince1970,
                lastUpdatedOn: bm.lastUpdatedOn.timeIntervalSince1970,
                wholeVerse: bm.wholeVerse,
                primaryLabelId: bm.primaryLabelId?.uuidString,
                notes: bm.notes?.notes,
                labelIds: bm.bookmarkToLabels?.compactMap { $0.label?.id.uuidString } ?? []
            )
        }

        // Labels
        let labels = store.labels(includeSystem: false)
        let labelBackups = labels.map { label in
            LabelBackup(
                id: label.id.uuidString,
                name: label.name,
                color: label.color,
                markerStyle: label.markerStyle,
                underlineStyle: label.underlineStyle,
                favourite: label.favourite
            )
        }

        // Reading plans
        let plans = planStore.plans()
        let planBackups = plans.map { plan in
            let completedDays = (plan.days ?? [])
                .filter(\.isCompleted)
                .map(\.dayNumber)
            return ReadingPlanBackup(
                id: plan.id.uuidString,
                planCode: plan.planCode,
                planName: plan.planName,
                startDate: plan.startDate.timeIntervalSince1970,
                currentDay: plan.currentDay,
                totalDays: plan.totalDays,
                isActive: plan.isActive,
                completedDays: completedDays
            )
        }

        // StudyPad entries
        var studyPadBackups: [StudyPadEntryBackup] = []
        for label in labels {
            let entries = store.studyPadEntries(labelId: label.id)
            for entry in entries {
                studyPadBackups.append(StudyPadEntryBackup(
                    id: entry.id.uuidString,
                    labelId: label.id.uuidString,
                    orderNumber: entry.orderNumber,
                    indentLevel: entry.indentLevel,
                    text: entry.textEntry?.text ?? ""
                ))
            }
        }

        let backup = AppBackup(
            timestamp: Date().timeIntervalSince1970,
            bookmarks: bookmarkBackups,
            labels: labelBackups,
            readingPlans: planBackups,
            studyPadEntries: studyPadBackups
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(backup)
    }

    // MARK: - Full JSON Restore

    /// Imports app data from a full JSON backup payload.
    /// - Parameter data: JSON backup data previously produced by `exportFullBackup()`.
    /// - Returns: Count of successfully inserted top-level rows.
    /// - Note: The import recreates reading-plan day rows from the matching built-in
    ///   `ReadingPlanService.availablePlans` template and restores completion state from
    ///   `completedDays`.
    public func importFullBackup(_ data: Data) -> Int {
        guard let backup = try? JSONDecoder().decode(AppBackup.self, from: data) else {
            return 0
        }

        var count = 0

        // Import labels first (bookmarks reference them)
        var labelMap: [String: Label] = [:]
        for lb in backup.labels {
            guard let id = UUID(uuidString: lb.id) else { continue }
            let label = Label(
                id: id,
                name: lb.name,
                color: lb.color,
                markerStyle: lb.markerStyle,
                underlineStyle: lb.underlineStyle,
                favourite: lb.favourite
            )
            modelContext.insert(label)
            labelMap[lb.id] = label
            count += 1
        }

        // Import bookmarks
        for bb in backup.bookmarks {
            guard let id = UUID(uuidString: bb.id) else { continue }
            let bookmark = BibleBookmark(
                id: id,
                kjvOrdinalStart: bb.kjvOrdinalStart,
                kjvOrdinalEnd: bb.kjvOrdinalEnd,
                ordinalStart: bb.ordinalStart,
                ordinalEnd: bb.ordinalEnd,
                v11n: bb.v11n,
                createdAt: Date(timeIntervalSince1970: bb.createdAt),
                lastUpdatedOn: Date(timeIntervalSince1970: bb.lastUpdatedOn),
                wholeVerse: bb.wholeVerse
            )
            bookmark.book = bb.book
            bookmark.primaryLabelId = bb.primaryLabelId.flatMap { UUID(uuidString: $0) }

            modelContext.insert(bookmark)

            // Notes
            if let noteText = bb.notes, !noteText.isEmpty {
                let notes = BibleBookmarkNotes(bookmarkId: id, notes: noteText)
                notes.bookmark = bookmark
                modelContext.insert(notes)
            }

            // Label associations
            for labelIdStr in bb.labelIds {
                if let label = labelMap[labelIdStr] {
                    let btl = BibleBookmarkToLabel()
                    btl.bookmark = bookmark
                    btl.label = label
                    modelContext.insert(btl)
                }
            }

            count += 1
        }

        // Import StudyPad entries
        for sp in backup.studyPadEntries {
            guard let id = UUID(uuidString: sp.id) else { continue }
            let entry = StudyPadTextEntry(
                id: id,
                orderNumber: sp.orderNumber,
                indentLevel: sp.indentLevel
            )
            if let labelId = sp.labelId, let label = labelMap[labelId] {
                entry.label = label
            }
            modelContext.insert(entry)

            let textEntry = StudyPadTextEntryText(
                studyPadTextEntryId: id,
                text: sp.text
            )
            textEntry.entry = entry
            modelContext.insert(textEntry)
            count += 1
        }

        // Import reading plans
        for pb in backup.readingPlans {
            guard let id = UUID(uuidString: pb.id) else { continue }
            let plan = ReadingPlan(
                id: id,
                planCode: pb.planCode,
                planName: pb.planName,
                startDate: Date(timeIntervalSince1970: pb.startDate),
                currentDay: pb.currentDay,
                totalDays: pb.totalDays,
                isActive: pb.isActive
            )
            modelContext.insert(plan)

            // Recreate day entries from the template, marking completed ones
            // Days are 1-based (matching ReadingPlanService.startPlan)
            if let template = ReadingPlanService.availablePlans.first(where: { $0.code == pb.planCode }) {
                let completedSet = Set(pb.completedDays)
                for day in 1...pb.totalDays {
                    let planDay = ReadingPlanDay(
                        dayNumber: day,
                        isCompleted: completedSet.contains(day),
                        readings: template.readingsForDay(day)
                    )
                    planDay.plan = plan
                    modelContext.insert(planDay)
                }
            }
            count += 1
        }

        try? modelContext.save()
        return count
    }

    // MARK: - CSV Import

    /// Imports Bible bookmarks from CSV data.
    /// - Parameter data: UTF-8 CSV data in the column order emitted by `exportBookmarksCSV()`.
    /// - Returns: Count of successfully inserted bookmark rows.
    /// - Note: CSV import restores primary-label IDs and note text when those optional columns are
    ///   present.
    public func importBookmarksCSV(_ data: Data) -> Int {
        guard let csv = String(data: data, encoding: .utf8) else { return 0 }
        let lines = csv.components(separatedBy: .newlines).dropFirst() // Skip header
        var importCount = 0

        for line in lines where !line.isEmpty {
            let fields = parseCSVLine(line)
            guard fields.count >= 6 else { continue }

            let id = UUID(uuidString: fields[0]) ?? UUID()
            let kjvStart = Int(fields[1]) ?? 0
            let kjvEnd = Int(fields[2]) ?? kjvStart
            let v11n = fields[3]
            let createdAt = Double(fields[4]).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let wholeVerse = fields[5] == "true"

            let bookmark = BibleBookmark(
                id: id,
                kjvOrdinalStart: kjvStart,
                kjvOrdinalEnd: kjvEnd,
                ordinalStart: kjvStart,
                ordinalEnd: kjvEnd,
                v11n: v11n,
                createdAt: createdAt,
                wholeVerse: wholeVerse
            )

            // Optional fields
            if fields.count > 6, let labelId = UUID(uuidString: fields[6]) {
                bookmark.primaryLabelId = labelId
            }
            if fields.count > 7, !fields[7].isEmpty {
                let notes = BibleBookmarkNotes(bookmarkId: id, notes: fields[7])
                notes.bookmark = bookmark
                modelContext.insert(notes)
            }

            modelContext.insert(bookmark)
            importCount += 1
        }

        try? modelContext.save()
        return importCount
    }

    /// Parse a CSV line handling quoted fields.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
