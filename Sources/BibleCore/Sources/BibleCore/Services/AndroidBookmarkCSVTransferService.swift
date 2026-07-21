// AndroidBookmarkCSVTransferService.swift -- Android-compatible bookmark CSV transfer

import Foundation
import SwiftData

/** Columns supported by Android's `BookmarkCsvUtils` semicolon-delimited contract. */
public enum AndroidBookmarkCSVColumn: String, CaseIterable, Hashable, Sendable {
    case osisReference = "osisRef"
    case bibleReference = "bibleRef"
    case document
    case book
    case chapterStart
    case verseStart
    case chapterEnd
    case verseEnd
    case id
    case ordinalStart
    case ordinalEnd
    case createdAt
    case lastUpdatedOn
    case startOffset
    case endOffset
    case labels
    case notes
    case customIcon
}

/** Summary returned after an atomic bookmark CSV import commits. */
public struct AndroidBookmarkCSVImportResult: Equatable, Sendable {
    /// Number of rows whose UUID did not already exist.
    public let created: Int

    /// Number of existing UUID rows replaced by imported values.
    public let updated: Int

    /** Creates an immutable import summary without side effects. */
    public init(created: Int, updated: Int) {
        self.created = created
        self.updated = updated
    }
}

/** Errors raised while parsing, validating, exporting, or atomically applying bookmark CSV. */
public enum AndroidBookmarkCSVError: Error, Equatable, LocalizedError, Sendable {
    case invalidUTF8
    case emptyDocument
    case unterminatedQuotedField(record: Int)
    case malformedQuotedField(record: Int)
    case duplicateHeader(String)
    case inconsistentColumnCount(record: Int, expected: Int, actual: Int)
    case duplicateBookmarkID(UUID)
    case duplicateStoredBookmarkID(UUID)
    case invalidIdentifier(record: Int, value: String)
    case invalidInteger(record: Int, column: String, value: String)
    case invalidDate(record: Int, column: String, value: String)
    case invalidReference(record: Int)
    case invalidExportBookmark(UUID)
    case noExportColumns

    /// User-visible transfer failure that identifies the malformed record when available.
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return String(localized: "csv_import_invalid_utf8", defaultValue: "The CSV file is not valid UTF-8.")
        case .emptyDocument:
            return String(localized: "csv_import_empty", defaultValue: "The CSV file is empty.")
        case .unterminatedQuotedField(let record):
            return "CSV record \(record) contains an unterminated quoted field."
        case .malformedQuotedField(let record):
            return "CSV record \(record) contains malformed quoting."
        case .duplicateHeader(let header):
            return "The CSV header contains \"\(header)\" more than once."
        case .inconsistentColumnCount(let record, let expected, let actual):
            return "CSV record \(record) has \(actual) columns; \(expected) were expected."
        case .duplicateBookmarkID(let id):
            return "The CSV file contains bookmark \(id.uuidString) more than once."
        case .duplicateStoredBookmarkID(let id):
            return "Stored bookmark \(id.uuidString) is duplicated and cannot be updated safely."
        case .invalidIdentifier(let record, let value):
            return "CSV record \(record) contains an invalid bookmark identifier: \(value)."
        case .invalidInteger(let record, let column, let value):
            return "CSV record \(record) contains an invalid \(column) value: \(value)."
        case .invalidDate(let record, let column, let value):
            return "CSV record \(record) contains an invalid \(column) date: \(value)."
        case .invalidReference(let record):
            return "CSV record \(record) does not contain a valid KJVA Bible reference."
        case .invalidExportBookmark(let id):
            return "Bookmark \(id.uuidString) does not contain a verified KJVA Bible reference."
        case .noExportColumns:
            return String(localized: "csv_export_no_columns", defaultValue: "Select at least one CSV column.")
        }
    }
}

/**
 Encodes and decodes Android's Bible-bookmark CSV wire format.

 The codec uses semicolons, UTF-8, doubled quote escapes, and multiline quoted fields exactly like
 Android. Decoding is strict and returns no records when any row is malformed, allowing the import
 service to guarantee all-or-nothing persistence.
 */
public enum AndroidBookmarkCSVCodec {
    /**
     Encodes Bible bookmarks using the selected Android columns in canonical column order.

     - Parameters:
       - bookmarks: Bible bookmarks to export in caller-provided display order.
       - selectedColumns: Columns selected by the user; output order always follows Android.
     - Returns: UTF-8 semicolon-delimited CSV bytes.
     - Side effects: Reads attached notes and labels from the supplied SwiftData objects.
     - Throws: `AndroidBookmarkCSVError.noExportColumns` when no supported column is selected.
     */
    public static func encode(
        bookmarks: [BibleBookmark],
        selectedColumns: Set<AndroidBookmarkCSVColumn> = Set(AndroidBookmarkCSVColumn.allCases)
    ) throws -> Data {
        let columns = AndroidBookmarkCSVColumn.allCases.filter(selectedColumns.contains)
        guard !columns.isEmpty else { throw AndroidBookmarkCSVError.noExportColumns }

        var rows: [[String]] = [columns.map(\.rawValue)]
        rows.reserveCapacity(bookmarks.count + 1)
        for bookmark in bookmarks {
            let endOrdinal = bookmark.kjvOrdinalEnd > 0
                ? bookmark.kjvOrdinalEnd
                : bookmark.kjvOrdinalStart
            guard bookmark.hasTrustedPersistedOrdinals,
                  JSwordKJVAVersification.verseReference(
                      ordinal: bookmark.kjvOrdinalStart
                  ) != nil,
                  JSwordKJVAVersification.verseReference(ordinal: endOrdinal) != nil else {
                throw AndroidBookmarkCSVError.invalidExportBookmark(bookmark.id)
            }
            let values = exportValues(for: bookmark)
            rows.append(columns.map { values[$0] ?? "" })
        }
        let text = rows.map { row in
            row.map(escape).joined(separator: ";")
        }.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    /**
     Parses and validates every CSV record without mutating persistence.

     - Parameter data: UTF-8 CSV bytes, optionally beginning with a UTF-8 BOM.
     - Returns: Fully validated import rows ready for one transaction.
     - Side effects: Reads the pinned KJVA canon and localized JSword book-name resources.
     - Throws: `AndroidBookmarkCSVError` for malformed CSV, duplicate IDs, invalid scalar fields,
       or references that cannot be resolved through Android's documented fallback order.
     */
    static func decode(_ data: Data) throws -> [ImportRow] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw AndroidBookmarkCSVError.invalidUTF8
        }
        if text.unicodeScalars.first?.value == 0xFEFF {
            text.removeFirst()
        }
        let records = try SemicolonCSVParser.parse(text)
        guard let headerRecord = records.first else {
            throw AndroidBookmarkCSVError.emptyDocument
        }
        var headerMap: [String: Int] = [:]
        for (index, header) in headerRecord.enumerated() {
            guard headerMap.updateValue(index, forKey: header) == nil else {
                throw AndroidBookmarkCSVError.duplicateHeader(header)
            }
        }

        var result: [ImportRow] = []
        var seenIDs: Set<UUID> = []
        for (offset, record) in records.dropFirst().enumerated() {
            let recordNumber = offset + 2
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            guard record.count == headerRecord.count else {
                throw AndroidBookmarkCSVError.inconsistentColumnCount(
                    record: recordNumber,
                    expected: headerRecord.count,
                    actual: record.count
                )
            }
            let row = try importRow(record, headerMap: headerMap, recordNumber: recordNumber)
            guard seenIDs.insert(row.id).inserted else {
                throw AndroidBookmarkCSVError.duplicateBookmarkID(row.id)
            }
            result.append(row)
        }
        return result
    }

    /// Parsed row whose values have passed all wire-format validation.
    struct ImportRow {
        let id: UUID
        let kjvaRange: ClosedRange<Int>
        let bookInitials: String
        let createdAt: Date
        let lastUpdatedOn: Date
        let startOffset: Int?
        let endOffset: Int?
        let labelsIncluded: Bool
        let labelNames: [String]
        let notes: String?
        let customIcon: String?
    }

    /** Builds one complete column-value map for export. */
    private static func exportValues(
        for bookmark: BibleBookmark
    ) -> [AndroidBookmarkCSVColumn: String] {
        let endOrdinal = bookmark.kjvOrdinalEnd > 0
            ? bookmark.kjvOrdinalEnd
            : bookmark.kjvOrdinalStart
        let start = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalStart)
        let end = JSwordKJVAVersification.verseReference(ordinal: endOrdinal)
        let osisReference: String
        if let start, let end {
            osisReference = start == end ? start.osisRef : "\(start.osisRef)-\(end.osisRef)"
        } else {
            osisReference = ""
        }
        let bibleReference = displayReference(start: start, end: end)
        let labelNames = (bookmark.bookmarkToLabels ?? [])
            .compactMap(\.label)
            .filter(\.isRealLabel)
            .map(\.name)
            .sorted()
            .joined(separator: ";")

        return [
            .osisReference: osisReference,
            .bibleReference: bibleReference,
            .document: bookmark.bookInitials,
            .book: start?.osisId ?? "",
            .chapterStart: start.map { String($0.chapter) } ?? "",
            .verseStart: start.map { String($0.verse) } ?? "",
            .chapterEnd: end.map { String($0.chapter) } ?? "",
            .verseEnd: end.map { String($0.verse) } ?? "",
            .id: bookmark.id.uuidString,
            .ordinalStart: String(bookmark.kjvOrdinalStart),
            .ordinalEnd: String(endOrdinal),
            .createdAt: formatDate(bookmark.createdAt),
            .lastUpdatedOn: formatDate(bookmark.lastUpdatedOn),
            .startOffset: bookmark.startOffset.map(String.init) ?? "",
            .endOffset: bookmark.endOffset.map(String.init) ?? "",
            .labels: labelNames,
            .notes: bookmark.notes?.notes ?? "",
            .customIcon: bookmark.customIcon ?? "",
        ]
    }

    /** Converts one raw record to the validated import representation. */
    private static func importRow(
        _ values: [String],
        headerMap: [String: Int],
        recordNumber: Int
    ) throws -> ImportRow {
        let rawID = value(.id, in: values, headerMap: headerMap) ?? ""
        let id: UUID
        if rawID.isEmpty {
            id = UUID()
        } else if let parsed = UUID(uuidString: rawID) {
            id = parsed
        } else {
            throw AndroidBookmarkCSVError.invalidIdentifier(record: recordNumber, value: rawID)
        }

        let range = try resolveRange(values, headerMap: headerMap, recordNumber: recordNumber)
        let createdAt = try date(
            value(.createdAt, in: values, headerMap: headerMap),
            column: .createdAt,
            recordNumber: recordNumber
        ) ?? Date()
        let lastUpdated = try date(
            value(.lastUpdatedOn, in: values, headerMap: headerMap),
            column: .lastUpdatedOn,
            recordNumber: recordNumber
        ) ?? Date()
        let startOffset = try integer(
            value(.startOffset, in: values, headerMap: headerMap),
            column: .startOffset,
            recordNumber: recordNumber
        )
        let endOffset = try integer(
            value(.endOffset, in: values, headerMap: headerMap),
            column: .endOffset,
            recordNumber: recordNumber
        )
        if (startOffset == nil) != (endOffset == nil) {
            throw AndroidBookmarkCSVError.invalidInteger(
                record: recordNumber,
                column: "text offsets",
                value: "\(startOffset.map(String.init) ?? "")...\(endOffset.map(String.init) ?? "")"
            )
        }

        let labelsIncluded = headerMap[AndroidBookmarkCSVColumn.labels.rawValue] != nil
        let labelNames = (value(.labels, in: values, headerMap: headerMap) ?? "")
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let noteValue = value(.notes, in: values, headerMap: headerMap)

        return ImportRow(
            id: id,
            kjvaRange: range,
            bookInitials: value(.document, in: values, headerMap: headerMap) ?? "",
            createdAt: createdAt,
            lastUpdatedOn: lastUpdated,
            startOffset: startOffset,
            endOffset: endOffset,
            labelsIncluded: labelsIncluded,
            labelNames: labelNames,
            notes: noteValue?.isEmpty == false ? noteValue : nil,
            customIcon: value(.customIcon, in: values, headerMap: headerMap).flatMap {
                $0.isEmpty ? nil : $0
            }
        )
    }

    /** Applies Android's ordinal, OSIS, discrete-coordinate, then display-reference lookup order. */
    private static func resolveRange(
        _ values: [String],
        headerMap: [String: Int],
        recordNumber: Int
    ) throws -> ClosedRange<Int> {
        if let start = try integer(
            value(.ordinalStart, in: values, headerMap: headerMap),
            column: .ordinalStart,
            recordNumber: recordNumber
        ) {
            let end = try integer(
                value(.ordinalEnd, in: values, headerMap: headerMap),
                column: .ordinalEnd,
                recordNumber: recordNumber
            ) ?? start
            if start <= end {
                let range = start...end
                if validKJVARange(range) { return range }
            }
        }

        if let osis = value(.osisReference, in: values, headerMap: headerMap),
           !osis.isEmpty,
           let range = kjvaRange(fromOSIS: osis) {
            return range
        }

        if let book = value(.book, in: values, headerMap: headerMap),
           let chapterStart = try integer(
               value(.chapterStart, in: values, headerMap: headerMap),
               column: .chapterStart,
               recordNumber: recordNumber
           ),
           let verseStart = try integer(
               value(.verseStart, in: values, headerMap: headerMap),
               column: .verseStart,
               recordNumber: recordNumber
           ) {
            let chapterEnd = try integer(
                value(.chapterEnd, in: values, headerMap: headerMap),
                column: .chapterEnd,
                recordNumber: recordNumber
            ) ?? chapterStart
            let verseEnd = try integer(
                value(.verseEnd, in: values, headerMap: headerMap),
                column: .verseEnd,
                recordNumber: recordNumber
            ) ?? verseStart
            let osis = "\(book).\(chapterStart).\(verseStart)-\(book).\(chapterEnd).\(verseEnd)"
            if let range = kjvaRange(fromOSIS: osis) { return range }
        }

        if let display = value(.bibleReference, in: values, headerMap: headerMap),
           let resolved = ScriptureReferenceLinker.resolve(
               display,
               documentLanguage: Locale.current.identifier,
               userLocale: .current
           )?.split(whereSeparator: { $0.isWhitespace }).first,
           let range = kjvaRange(fromOSIS: String(resolved)) {
            return range
        }
        throw AndroidBookmarkCSVError.invalidReference(record: recordNumber)
    }

    /** Resolves one exact KJVA OSIS verse/range into inclusive Android ordinals. */
    private static func kjvaRange(fromOSIS rawValue: String) -> ClosedRange<Int>? {
        guard let range = SpeakVerseRange(
                  versification: JSwordKJVAVersification.name,
                  osisRef: rawValue
              ),
              let references = range.validatedReferences(),
              let start = JSwordKJVAVersification.verseOrdinal(
                  osisId: references.start.osisBookId,
                  chapter: references.start.chapter,
                  verse: references.start.verse
              ),
              let end = JSwordKJVAVersification.verseOrdinal(
                  osisId: references.end.osisBookId,
                  chapter: references.end.chapter,
                  verse: references.end.verse
              ),
              start <= end else {
            return nil
        }
        return start...end
    }

    /** Confirms both endpoints resolve to concrete KJVA verses and preserve ordering. */
    private static func validKJVARange(_ range: ClosedRange<Int>) -> Bool {
        range.lowerBound > 0 &&
            JSwordKJVAVersification.verseReference(ordinal: range.lowerBound) != nil &&
            JSwordKJVAVersification.verseReference(ordinal: range.upperBound) != nil
    }

    /** Reads one named field from a parsed record. */
    private static func value(
        _ column: AndroidBookmarkCSVColumn,
        in values: [String],
        headerMap: [String: Int]
    ) -> String? {
        guard let index = headerMap[column.rawValue], values.indices.contains(index) else { return nil }
        return values[index]
    }

    /** Parses an optional strict base-10 integer. */
    private static func integer(
        _ rawValue: String?,
        column: AndroidBookmarkCSVColumn,
        recordNumber: Int
    ) throws -> Int? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        guard let result = Int(rawValue) else {
            throw AndroidBookmarkCSVError.invalidInteger(
                record: recordNumber,
                column: column.rawValue,
                value: rawValue
            )
        }
        return result
    }

    /** Parses Android's fixed UTC second-resolution date format. */
    private static func date(
        _ rawValue: String?,
        column: AndroidBookmarkCSVColumn,
        recordNumber: Int
    ) throws -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        guard let result = dateFormatter().date(from: rawValue) else {
            throw AndroidBookmarkCSVError.invalidDate(
                record: recordNumber,
                column: column.rawValue,
                value: rawValue
            )
        }
        return result
    }

    /** Formats a date exactly like Android's UTC `SimpleDateFormat`. */
    private static func formatDate(_ date: Date) -> String {
        dateFormatter().string(from: date)
    }

    /** Creates an isolated formatter because `DateFormatter` is mutable and not Sendable. */
    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        return formatter
    }

    /** Produces Android's English fallback Bible range label for export. */
    private static func displayReference(
        start: JSwordKJVAVerseReference?,
        end: JSwordKJVAVerseReference?
    ) -> String {
        guard let start, let end else { return "" }
        let startBook = JSwordKJVAVersification.longBookName(osisId: start.osisId) ?? start.osisId
        let endBook = JSwordKJVAVersification.longBookName(osisId: end.osisId) ?? end.osisId
        if start == end { return "\(startBook) \(start.chapter):\(start.verse)" }
        if start.osisId == end.osisId, start.chapter == end.chapter {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.verse)"
        }
        if start.osisId == end.osisId {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.chapter):\(end.verse)"
        }
        return "\(startBook) \(start.chapter):\(start.verse)-\(endBook) \(end.chapter):\(end.verse)"
    }

    /** Applies RFC-style quote escaping around fields that need it. */
    private static func escape(_ field: String) -> String {
        guard field.contains(";") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/**
 Atomically merges a validated Android bookmark CSV document into SwiftData.

 Parsing and scalar validation finish before the transaction begins. Existing bookmarks merge only
 by UUID; missing IDs create new rows. Notes replace or clear the existing note on UUID updates,
 matching Android even when that optional export column is omitted. A non-empty labels field
 replaces label membership, creating missing labels by exact trimmed name, while an omitted or empty
 labels field preserves membership like Android. Any mutation or commit error rolls the complete
 import back.
 */
@MainActor
public final class AndroidBookmarkCSVTransferService {
    /// Context owning bookmarks, notes, labels, and junction rows.
    private let modelContext: ModelContext

    /**
     Creates a CSV transfer service bound to one SwiftData context.

     - Parameter modelContext: Clean caller-confined context used for the complete import transaction.
     - Side effects: None until `importCSV(_:)` is called.
     - Failure modes: Construction cannot fail.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     Validates and atomically imports one Android bookmark CSV file.

     - Parameter data: UTF-8 semicolon-delimited CSV bytes.
     - Returns: Created and updated row counts after commit.
     - Side effects: Inserts or updates Bible bookmarks, notes, labels, and junctions in one
       SwiftData transaction.
     - Throws: `AndroidBookmarkCSVError` before mutation for malformed input, or a SwiftData error
       from fetch/commit. Any failed transaction is rolled back before the error escapes.
     - Important: The supplied context must not be concurrently mutated while this method runs.
     */
    public func importCSV(_ data: Data) throws -> AndroidBookmarkCSVImportResult {
        let rows = try AndroidBookmarkCSVCodec.decode(data)
        let existingBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let existingLabels = try modelContext.fetch(FetchDescriptor<Label>())
        var bookmarksByID: [UUID: BibleBookmark] = [:]
        for bookmark in existingBookmarks {
            guard bookmarksByID.updateValue(bookmark, forKey: bookmark.id) == nil else {
                throw AndroidBookmarkCSVError.duplicateStoredBookmarkID(bookmark.id)
            }
        }
        var labelsByName: [String: Label] = [:]
        for label in existingLabels {
            let normalizedName = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedName.isEmpty {
                labelsByName[normalizedName] = label
            }
        }

        var created = 0
        var updated = 0
        do {
            try modelContext.transaction {
                for row in rows {
                    let bookmark: BibleBookmark
                    if let existing = bookmarksByID[row.id] {
                        bookmark = existing
                        updated += 1
                    } else {
                        bookmark = BibleBookmark(id: row.id)
                        modelContext.insert(bookmark)
                        bookmarksByID[row.id] = bookmark
                        created += 1
                    }
                    apply(row, to: bookmark)
                    applyNotes(row, to: bookmark)
                    if row.labelsIncluded, !row.labelNames.isEmpty {
                        applyLabels(
                            row.labelNames,
                            to: bookmark,
                            labelsByName: &labelsByName
                        )
                    }
                }
            }
        } catch {
            if modelContext.hasChanges { modelContext.rollback() }
            throw error
        }
        return AndroidBookmarkCSVImportResult(created: created, updated: updated)
    }

    /** Applies scalar row values and verified KJVA provenance to one bookmark. */
    private func apply(_ row: AndroidBookmarkCSVCodec.ImportRow, to bookmark: BibleBookmark) {
        bookmark.kjvOrdinalStart = row.kjvaRange.lowerBound
        bookmark.kjvOrdinalEnd = row.kjvaRange.upperBound
        bookmark.ordinalStart = row.kjvaRange.lowerBound
        bookmark.ordinalEnd = row.kjvaRange.upperBound
        bookmark.v11n = JSwordKJVAVersification.name
        bookmark.bookInitials = row.bookInitials
        bookmark.book = nil
        bookmark.createdAt = row.createdAt
        bookmark.lastUpdatedOn = row.lastUpdatedOn
        bookmark.startOffset = row.startOffset
        bookmark.endOffset = row.endOffset
        bookmark.wholeVerse = row.startOffset == nil && row.endOffset == nil
        bookmark.customIcon = row.customIcon
        bookmark.ordinalTrustMetadata = PersistedOrdinalTrustPolicy.androidImportMetadata(
            sourceVersification: JSwordKJVAVersification.name,
            sourceOrdinalStart: row.kjvaRange.lowerBound,
            sourceOrdinalEnd: row.kjvaRange.upperBound,
            kjvaOrdinalStart: row.kjvaRange.lowerBound,
            kjvaOrdinalEnd: row.kjvaRange.upperBound
        )
    }

    /** Replaces or clears note content exactly as Android's UUID-update path does. */
    private func applyNotes(_ row: AndroidBookmarkCSVCodec.ImportRow, to bookmark: BibleBookmark) {
        if let notes = row.notes {
            if let existing = bookmark.notes {
                existing.notes = notes
            } else {
                let note = BibleBookmarkNotes(bookmarkId: bookmark.id, notes: notes)
                note.bookmark = bookmark
                bookmark.notes = note
                modelContext.insert(note)
            }
        } else if let existing = bookmark.notes {
            bookmark.notes = nil
            modelContext.delete(existing)
        }
    }

    /** Replaces label junctions with exact-name labels, creating missing labels as Android does. */
    private func applyLabels(
        _ names: [String],
        to bookmark: BibleBookmark,
        labelsByName: inout [String: Label]
    ) {
        for link in bookmark.bookmarkToLabels ?? [] {
            modelContext.delete(link)
        }
        bookmark.bookmarkToLabels = []

        var appliedIDs: Set<UUID> = []
        for name in names where !name.isEmpty {
            let label: Label
            if let existing = labelsByName[name] {
                label = existing
            } else {
                label = Label(name: name, color: Label.defaultColor)
                modelContext.insert(label)
                labelsByName[name] = label
            }
            guard appliedIDs.insert(label.id).inserted else { continue }
            let link = BibleBookmarkToLabel()
            link.bookmark = bookmark
            link.label = label
            modelContext.insert(link)
        }
        bookmark.primaryLabelId = names.first.flatMap { labelsByName[$0]?.id }
    }
}

/** Strict semicolon CSV parser supporting escaped quotes, CRLF, BOM stripping, and multiline fields. */
private enum SemicolonCSVParser {
    /**
     Parses a complete text document into records.

     - Parameter text: BOM-free UTF-8 text.
     - Returns: Records and fields with quote escaping removed and embedded newlines preserved.
     - Side effects: None.
     - Throws: `AndroidBookmarkCSVError` for unterminated or structurally malformed quoting.
     */
    static func parse(_ text: String) throws -> [[String]] {
        guard !text.isEmpty else { throw AndroidBookmarkCSVError.emptyDocument }
        let characters = Array(text)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var closedQuotedField = false
        var recordStarted = false
        var index = 0

        func finishField() {
            record.append(field)
            field = ""
            closedQuotedField = false
        }
        func finishRecord() {
            finishField()
            records.append(record)
            record = []
            recordStarted = false
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    closedQuotedField = true
                } else if character == "\r" {
                    field.append("\n")
                    if index + 1 < characters.count, characters[index + 1] == "\n" {
                        index += 1
                    }
                } else {
                    field.append(character)
                }
                index += 1
                continue
            }

            if closedQuotedField, character != ";", character != "\n", character != "\r" {
                throw AndroidBookmarkCSVError.malformedQuotedField(record: records.count + 1)
            }
            switch character {
            case "\"":
                guard field.isEmpty else {
                    throw AndroidBookmarkCSVError.malformedQuotedField(record: records.count + 1)
                }
                inQuotes = true
                recordStarted = true
            case ";":
                finishField()
                recordStarted = true
            case "\n", "\r":
                finishRecord()
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
            default:
                field.append(character)
                recordStarted = true
            }
            index += 1
        }

        guard !inQuotes else {
            throw AndroidBookmarkCSVError.unterminatedQuotedField(record: records.count + 1)
        }
        if recordStarted || !record.isEmpty || !field.isEmpty {
            finishRecord()
        }
        return records
    }
}
