import BibleCore
import Foundation

/**
 Android Reading Progress Memorization presentation model.

 Android builds the Memorization tab from KJVA-normalized progress rows, not from the active SWORD
 module's book list. This model keeps the same contract for SwiftUI: memorized passages are grouped
 by consecutive KJVA ordinals, memorization targets remain independent rows, overview cells cover
 every JSword `SystemKJVA` scripture book, and calendar counts are bucketed by local day.
 */
struct MemorizationProgressPresentation: Equatable {
    struct Summary: Equatable {
        let totalMemorized: Int
        let targetMemorized: Int
        let targetTotal: Int
    }

    struct MemorizedPassage: Equatable, Identifiable {
        var id: String { "\(range.startOrdinal)-\(range.endOrdinal)-\(latestMemorizedAt)" }
        let title: String
        let range: MemorizationProgressRange
        let latestMemorizedAt: Int64
    }

    struct TargetItem: Equatable, Identifiable {
        let id: UUID
        let title: String
        let row: MemorizationTargetRow
        let memorizedCount: Int
        let verseCount: Int
        let createdAt: Int64

        var progressFraction: Double {
            guard verseCount > 0 else { return 0 }
            return Double(memorizedCount) / Double(verseCount)
        }
    }

    struct BookCell: Equatable, Identifiable {
        var id: String { osisId }
        let osisId: String
        let title: String
        let shortTitle: String
        let isNewTestament: Bool
        let memorizedVerseCount: Int
        let totalVerseCount: Int
        let hasTarget: Bool

        var progressFraction: Double {
            guard totalVerseCount > 0 else { return 0 }
            return Double(memorizedVerseCount) / Double(totalVerseCount)
        }

        var progressBucket: MemorizationProgressBucket {
            MemorizationProgressBucket(fraction: progressFraction)
        }
    }

    struct ChapterCell: Equatable, Identifiable {
        var id: Int { chapter }
        let chapter: Int
        let memorizedVerseCount: Int
        let totalVerseCount: Int
        let hasTarget: Bool

        var progressFraction: Double {
            guard totalVerseCount > 0 else { return 0 }
            return Double(memorizedVerseCount) / Double(totalVerseCount)
        }

        var progressBucket: MemorizationProgressBucket {
            MemorizationProgressBucket(fraction: progressFraction)
        }
    }

    struct ChapterDetail: Equatable {
        let osisId: String
        let title: String
        let chapters: [ChapterCell]
    }

    let summary: Summary
    let memorizedPassages: [MemorizedPassage]
    let incompleteTargets: [TargetItem]
    let books: [BookCell]
    let calendarCountsByDayStartMilliseconds: [Int64: Int]

    private let snapshot: MemorizationProgressSnapshot
    private let memorizedOrdinals: Set<Int>
    private let targetRows: [MemorizationTargetRow]

    init(
        snapshot: MemorizationProgressSnapshot,
        nowMilliseconds: Int64 = Int64((Date().timeIntervalSince1970 * 1000.0).rounded()),
        calendar: Calendar = .current
    ) {
        self.snapshot = snapshot
        memorizedOrdinals = Set(snapshot.memorizedVerses.map(\.kjvOrdinal))
        targetRows = snapshot.targetRows

        let targetItems = Self.targetItems(from: targetRows, memorizedOrdinals: memorizedOrdinals)
        incompleteTargets = targetItems.filter { $0.memorizedCount < $0.verseCount }
        summary = Summary(
            totalMemorized: memorizedOrdinals.count,
            targetMemorized: targetItems.reduce(0) { $0 + $1.memorizedCount },
            targetTotal: targetItems.reduce(0) { $0 + $1.verseCount }
        )
        memorizedPassages = Self.memorizedPassages(from: snapshot.memorizedVerses)
        books = Self.bookCells(memorizedOrdinals: memorizedOrdinals, targetRows: targetRows)
        calendarCountsByDayStartMilliseconds = Self.calendarCounts(
            verses: snapshot.memorizedVerses,
            nowMilliseconds: nowMilliseconds,
            calendar: calendar
        )
    }

    func chapterDetail(osisId: String) -> ChapterDetail? {
        guard let book = JSwordKJVAVersification.books.first(where: { $0.osisId == osisId }) else {
            return nil
        }
        let chapters = (1...book.chapterCount).compactMap { chapter -> ChapterCell? in
            guard let range = JSwordKJVAVersification.verseOrdinalRange(osisId: osisId, chapter: chapter),
                  let verseCount = JSwordKJVAVersification.verseCount(osisId: osisId, chapter: chapter) else {
                return nil
            }
            return ChapterCell(
                chapter: chapter,
                memorizedVerseCount: countMemorized(in: range),
                totalVerseCount: verseCount,
                hasTarget: targetRows.contains { Self.overlaps($0.range, range) }
            )
        }
        return ChapterDetail(
            osisId: osisId,
            title: book.longName,
            chapters: chapters
        )
    }

    private func countMemorized(in range: ClosedRange<Int>) -> Int {
        memorizedOrdinals.reduce(0) { total, ordinal in
            total + (range.contains(ordinal) ? 1 : 0)
        }
    }

    private static func memorizedPassages(
        from verses: [MemorizedVerseProgress]
    ) -> [MemorizedPassage] {
        let sorted = latestMemorizedVerseRows(from: verses).sorted { $0.kjvOrdinal < $1.kjvOrdinal }
        guard let first = sorted.first else { return [] }

        var result: [MemorizedPassage] = []
        var start = first.kjvOrdinal
        var end = first.kjvOrdinal
        var latest = first.memorizedAt

        for verse in sorted.dropFirst() {
            if verse.kjvOrdinal == end + 1 {
                end = verse.kjvOrdinal
                latest = max(latest, verse.memorizedAt)
                continue
            }
            result.append(passage(start: start, end: end, latest: latest))
            start = verse.kjvOrdinal
            end = verse.kjvOrdinal
            latest = verse.memorizedAt
        }
        result.append(passage(start: start, end: end, latest: latest))

        return result.sorted {
            if $0.latestMemorizedAt != $1.latestMemorizedAt {
                return $0.latestMemorizedAt > $1.latestMemorizedAt
            }
            return $0.range.startOrdinal < $1.range.startOrdinal
        }
    }

    private static func latestMemorizedVerseRows(
        from verses: [MemorizedVerseProgress]
    ) -> [MemorizedVerseProgress] {
        var rowByOrdinal: [Int: MemorizedVerseProgress] = [:]
        for verse in verses where JSwordKJVAVersification.containsProgressOrdinal(verse.kjvOrdinal) {
            let existing = rowByOrdinal[verse.kjvOrdinal]
            guard existing == nil || (existing?.memorizedAt ?? 0) < verse.memorizedAt else {
                continue
            }
            rowByOrdinal[verse.kjvOrdinal] = verse
        }
        return rowByOrdinal.values.sorted { $0.kjvOrdinal < $1.kjvOrdinal }
    }

    private static func passage(start: Int, end: Int, latest: Int64) -> MemorizedPassage {
        let range = MemorizationProgressRange(bookInitials: "", startOrdinal: start, endOrdinal: end)
        return MemorizedPassage(
            title: title(for: range),
            range: range,
            latestMemorizedAt: latest
        )
    }

    private static func targetItems(
        from rows: [MemorizationTargetRow],
        memorizedOrdinals: Set<Int>
    ) -> [TargetItem] {
        rows.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        .map { row in
            TargetItem(
                id: row.id,
                title: title(for: row.range),
                row: row,
                memorizedCount: memorizedOrdinals.reduce(0) { total, ordinal in
                    total + (ordinal >= row.startOrdinal && ordinal <= row.endOrdinal ? 1 : 0)
                },
                verseCount: row.verseCount,
                createdAt: row.createdAt
            )
        }
    }

    private static func bookCells(
        memorizedOrdinals: Set<Int>,
        targetRows: [MemorizationTargetRow]
    ) -> [BookCell] {
        JSwordKJVAVersification.books.map { book in
            let range = JSwordKJVAVersification.verseOrdinalRange(osisId: book.osisId)
            let totalOrdinalCount = range?.count ?? 0
            let memorized = range.map { range in
                memorizedOrdinals.reduce(0) { total, ordinal in
                    total + (range.contains(ordinal) ? 1 : 0)
                }
            } ?? 0
            return BookCell(
                osisId: book.osisId,
                title: book.longName,
                shortTitle: book.shortName,
                isNewTestament: book.isNewTestament,
                memorizedVerseCount: memorized,
                totalVerseCount: totalOrdinalCount,
                hasTarget: range.map { bookRange in
                    targetRows.contains { overlaps($0.range, bookRange) }
                } ?? false
            )
        }
    }

    private static func calendarCounts(
        verses: [MemorizedVerseProgress],
        nowMilliseconds: Int64,
        calendar: Calendar
    ) -> [Int64: Int] {
        let now = Date(timeIntervalSince1970: TimeInterval(nowMilliseconds) / 1000.0)
        let start = calendar.date(byAdding: .weekOfYear, value: -52, to: now) ?? now
        let startMilliseconds = Int64((start.timeIntervalSince1970 * 1000.0).rounded())

        var counts: [Int64: Int] = [:]
        for verse in latestMemorizedVerseRows(from: verses)
            where verse.memorizedAt >= startMilliseconds && verse.memorizedAt <= nowMilliseconds {
            let dayStart = localDayStartMilliseconds(verse.memorizedAt, calendar: calendar)
            counts[dayStart, default: 0] += 1
        }
        return counts
    }

    private static func localDayStartMilliseconds(_ timestamp: Int64, calendar: Calendar) -> Int64 {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return Int64((calendar.startOfDay(for: date).timeIntervalSince1970 * 1000.0).rounded())
    }

    private static func title(for range: MemorizationProgressRange) -> String {
        guard let start = JSwordKJVAVersification.verseReference(ordinal: range.startOrdinal),
              let end = JSwordKJVAVersification.verseReference(ordinal: range.endOrdinal) else {
            return "\(range.startOrdinal)-\(range.endOrdinal)"
        }

        let startBook = bookTitle(osisId: start.osisId)
        if start.osisId != end.osisId {
            return "\(startBook) \(start.chapter):\(start.verse)-\(bookTitle(osisId: end.osisId)) \(end.chapter):\(end.verse)"
        }
        if start.chapter != end.chapter {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.chapter):\(end.verse)"
        }
        if start.verse != end.verse {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.verse)"
        }
        return "\(startBook) \(start.chapter):\(start.verse)"
    }

    private static func bookTitle(osisId: String) -> String {
        JSwordKJVAVersification.longBookName(osisId: osisId) ?? osisId
    }

    private static func overlaps(_ range: MemorizationProgressRange, _ query: ClosedRange<Int>) -> Bool {
        range.endOrdinal >= query.lowerBound && range.startOrdinal <= query.upperBound
    }
}

enum MemorizationProgressBucket: Equatable {
    case empty
    case low
    case medium
    case high
    case full

    init(fraction: Double) {
        switch fraction {
        case ...0:
            self = .empty
        case ..<0.25:
            self = .low
        case ..<0.5:
            self = .medium
        case ..<0.75:
            self = .high
        default:
            self = .full
        }
    }
}
