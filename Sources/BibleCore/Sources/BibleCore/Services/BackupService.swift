// BackupService.swift — Data export/import

import Foundation
import SwiftData

/// Codable backup format for full app data.
public struct AppBackup: Codable {
    public var version: Int = 1
    public var timestamp: Double
    public var platform: String = "iOS"
    public var bookmarks: [BookmarkBackup]
    public var labels: [LabelBackup]
    public var readingPlans: [ReadingPlanBackup]
    public var studyPadEntries: [StudyPadEntryBackup]
}

public struct BookmarkBackup: Codable {
    public var id: String
    public var kjvOrdinalStart: Int
    public var kjvOrdinalEnd: Int
    public var ordinalStart: Int
    public var ordinalEnd: Int
    public var v11n: String
    public var book: String?
    public var createdAt: Double
    public var lastUpdatedOn: Double
    public var wholeVerse: Bool
    public var primaryLabelId: String?
    public var notes: String?
    public var labelIds: [String]
}

public struct LabelBackup: Codable {
    public var id: String
    public var name: String
    public var color: Int
    public var markerStyle: Bool
    public var underlineStyle: Bool
    public var favourite: Bool
}

public struct ReadingPlanBackup: Codable {
    public var id: String
    public var planCode: String
    public var planName: String
    public var startDate: Double
    public var currentDay: Int
    public var totalDays: Int
    public var isActive: Bool
    public var completedDays: [Int]
}

public struct StudyPadEntryBackup: Codable {
    public var id: String
    public var labelId: String?
    public var orderNumber: Int
    public var indentLevel: Int
    public var text: String
}

/// Manages backup (export) and restore (import) of app data.
@Observable
public final class BackupService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CSV Export (Bookmarks)

    /// Export all bookmarks as CSV data.
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

    /// Export all app data as a JSON backup.
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

    /// Import app data from a JSON backup. Returns count of items imported.
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
            if let template = ReadingPlanService.availablePlans.first(where: { $0.code == pb.planCode }) {
                let completedSet = Set(pb.completedDays)
                for day in 0..<pb.totalDays {
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

    /// Import bookmarks from CSV data. Returns count of imported items.
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
