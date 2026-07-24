// AgentStudyPadAccess.swift -- Android-compatible StudyPad AI operations

import BibleCore
import Foundation
import SwordKit

private enum BibleUIAgentStudyPadEntryValue {
    case text(StudyPadTextEntry)
    case bible(BibleBookmarkToLabel, BibleBookmark)
    case generic(GenericBookmarkToLabel, GenericBookmark)

    var orderNumber: Int {
        switch self {
        case .text(let entry): return entry.orderNumber
        case .bible(let relation, _): return relation.orderNumber
        case .generic(let relation, _): return relation.orderNumber
        }
    }

    var stableRank: Int {
        switch self {
        case .text: return 0
        case .bible: return 1
        case .generic: return 2
        }
    }

    var id: UUID {
        switch self {
        case .text(let entry): return entry.id
        case .bible(_, let bookmark): return bookmark.id
        case .generic(_, let bookmark): return bookmark.id
        }
    }
}

@MainActor
extension BibleUIAgentDomainAdapter {
    /** Returns one StudyPad using Android's full, info, index, or page envelope. */
    func getStudyPadContent(
        labelID: UUID,
        mode: BibleUIAgentStudyPadReadMode,
        offset: Int,
        limit: Int
    ) throws -> AgentToolResult {
        guard let label = bookmarkService.label(id: labelID) else {
            throw studyPadDomainError(
                "LABEL_NOT_FOUND",
                "Label not found: \(labelID.uuidString.lowercased())"
            )
        }
        let items = orderedStudyPadItems(labelID: labelID)
        guard items.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw studyPadDomainError(
                "LIMIT_EXCEEDED",
                "The StudyPad contains too many entries for one tool result."
            )
        }

        switch mode {
        case .full:
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("labelId", BibleUIAgentJSON.uuid(labelID)),
                ("labelName", .string(label.name)),
                ("entryCount", BibleUIAgentJSON.integer(items.count)),
                ("entries", .array(items.map(fullStudyPadEntryJSON)))
            ))
        case .info:
            var textCount = 0
            var bibleCount = 0
            var genericCount = 0
            var estimatedLength = 0
            for item in items {
                switch item {
                case .text(let entry):
                    textCount += 1
                    estimatedLength += entry.textEntry?.text.utf16.count ?? 0
                case .bible(_, let bookmark):
                    bibleCount += 1
                    estimatedLength += bookmark.notes?.notes.utf16.count ?? 0
                case .generic(_, let bookmark):
                    genericCount += 1
                    estimatedLength += bookmark.notes?.notes.utf16.count ?? 0
                }
            }
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("labelId", BibleUIAgentJSON.uuid(labelID)),
                ("labelName", .string(label.name)),
                ("totalEntries", BibleUIAgentJSON.integer(items.count)),
                ("textEntryCount", BibleUIAgentJSON.integer(textCount)),
                ("bibleBookmarkCount", BibleUIAgentJSON.integer(bibleCount)),
                ("genericBookmarkCount", BibleUIAgentJSON.integer(genericCount)),
                ("estimatedTextLength", BibleUIAgentJSON.integer(estimatedLength))
            ))
        case .index:
            let values = items.enumerated().map { position, item in
                indexStudyPadEntryJSON(item, position: position)
            }
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("labelId", BibleUIAgentJSON.uuid(labelID)),
                ("labelName", .string(label.name)),
                ("totalEntries", BibleUIAgentJSON.integer(items.count)),
                ("entries", .array(values))
            ))
        case .page:
            let page = Array(items.dropFirst(min(offset, items.count)).prefix(limit))
            return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
                ("labelId", BibleUIAgentJSON.uuid(labelID)),
                ("labelName", .string(label.name)),
                ("totalEntries", BibleUIAgentJSON.integer(items.count)),
                ("offset", BibleUIAgentJSON.integer(offset)),
                ("limit", BibleUIAgentJSON.integer(limit)),
                ("hasMore", .bool(offset + limit < items.count)),
                ("entries", .array(page.map(fullStudyPadEntryJSON)))
            ))
        }
    }

    /** Searches StudyPad text and both bookmark-note tables using Android snippet ordering. */
    func searchStudyPads(query: String) throws -> AgentToolResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw studyPadDomainError("INVALID_ARGS", "Missing required parameter: query")
        }
        try Task.checkCancellation()
        let documents = StudyPadContentSearch.documents(from: bookmarkService.allLabels())
        let results = StudyPadContentSearch.search(documents: documents, query: normalizedQuery)
        let totalMatchCount = results.reduce(0) { $0 + $1.matchCount }
        guard totalMatchCount <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw studyPadDomainError(
                "LIMIT_EXCEEDED",
                "The StudyPad search returned too many matches."
            )
        }

        let values = results.map { result in
            BibleUIAgentJSON.object(
                ("labelId", BibleUIAgentJSON.uuid(result.labelID)),
                ("labelName", .string(result.labelName)),
                ("matchCount", BibleUIAgentJSON.integer(result.matchCount)),
                ("matches", .array(result.matches.map { match in
                    BibleUIAgentJSON.object(
                        ("entryId", BibleUIAgentJSON.uuid(match.entryID)),
                        ("entryType", .string(match.entryType.rawValue)),
                        ("textSnippet", .string(match.textSnippet))
                    )
                }))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("query", .string(query)),
            ("studyPadCount", BibleUIAgentJSON.integer(values.count)),
            ("results", .array(values))
        ))
    }

    /** Inserts an AI-owned text row at Android's requested mixed-entry position. */
    func addStudyPadEntry(
        labelID: UUID,
        text: String,
        contentType: BibleUIAgentNoteContentType,
        orderNumber: Int?,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        guard let label = bookmarkService.label(id: labelID) else {
            throw studyPadDomainError(
                "LABEL_NOT_FOUND",
                "Label not found: \(labelID.uuidString.lowercased())"
            )
        }
        let normalized = BibleUIAgentToolRequestParser.normalizeModelText(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw studyPadDomainError("INVALID_ARGS", "Missing required parameter: text")
        }
        let count = orderedStudyPadItems(labelID: labelID).count
        let desiredOrder = min(orderNumber ?? count, count)
        guard let created = bookmarkService.createStudyPadEntry(
            labelId: labelID,
            afterOrderNumber: desiredOrder - 1,
            contentType: contentType.rawValue
        )?.0 else {
            throw studyPadDomainError("ADD_ERROR", "The StudyPad entry could not be created.")
        }
        created.sourcePromptId = context.promptId
        bookmarkService.updateStudyPadTextEntry(
            id: created.id,
            orderNumber: desiredOrder,
            indentLevel: 0
        )
        bookmarkService.updateStudyPadTextEntryText(id: created.id, text: normalized)

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("entryId", BibleUIAgentJSON.uuid(created.id)),
            ("labelId", BibleUIAgentJSON.uuid(labelID)),
            ("labelName", .string(label.name)),
            ("textLength", BibleUIAgentJSON.integer(normalized.utf16.count)),
            ("contentType", .string(contentType.rawValue)),
            ("orderNumber", BibleUIAgentJSON.integer(created.orderNumber))
        ))
    }

    /** Replaces one existing StudyPad text payload. */
    func updateStudyPadTextEntry(entryID: UUID, text: String) throws -> AgentToolResult {
        let normalized = BibleUIAgentToolRequestParser.normalizeModelText(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw studyPadDomainError("INVALID_ARGS", "Missing required parameter: text")
        }
        guard bookmarkService.studyPadEntry(id: entryID) != nil else {
            throw studyPadDomainError(
                "ENTRY_NOT_FOUND",
                "StudyPad text entry not found: \(entryID.uuidString.lowercased())"
            )
        }
        bookmarkService.updateStudyPadTextEntryText(id: entryID, text: normalized)
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("entryId", BibleUIAgentJSON.uuid(entryID)),
            ("textLength", BibleUIAgentJSON.integer(normalized.utf16.count))
        ))
    }

    /** Creates a uniquely named StudyPad and its ordered mixed content. */
    func createStudyPad(
        name: String,
        color: Int?,
        items: [BibleUIAgentStudyPadItem],
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw studyPadDomainError("INVALID_ARGS", "Missing required parameter: name")
        }
        guard !items.isEmpty else {
            throw studyPadDomainError("EMPTY_ITEMS", "Items array must not be empty")
        }
        let labelName = uniqueStudyPadName(
            trimmedName,
            existingNames: bookmarkService.allLabels().map(\.name)
        )
        let label = bookmarkService.createLabel(
            name: labelName,
            color: color.flatMap { $0 == 0 ? nil : $0 } ?? Label.defaultColor
        )
        bookmarkService.ensureSystemLabels()

        var textCount = 0
        var bookmarkCount = 0
        var errors: [JSONValue] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            do {
                switch item.kind {
                case .text:
                    let normalized = BibleUIAgentToolRequestParser.normalizeModelText(item.text ?? "")
                    guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw studyPadDomainError("EMPTY_TEXT", "Empty text content")
                    }
                    guard let entry = bookmarkService.createStudyPadEntry(
                        labelId: label.id,
                        afterOrderNumber: index - 1,
                        contentType: item.contentType.rawValue
                    )?.0 else {
                        throw studyPadDomainError("ADD_ERROR", "The text entry could not be created.")
                    }
                    entry.sourcePromptId = context.promptId
                    bookmarkService.updateStudyPadTextEntry(
                        id: entry.id,
                        orderNumber: index,
                        indentLevel: item.indentLevel
                    )
                    bookmarkService.updateStudyPadTextEntryText(id: entry.id, text: normalized)
                    textCount += 1
                case .bookmark:
                    guard let reference = item.verseReference,
                          !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw studyPadDomainError("MISSING_REFERENCE", "Missing verseRef")
                    }
                    let range = try studyPadVerifiedRange(
                        reference: reference,
                        activeBookInitials: context.activeDocumentInitials
                    )
                    let bookmark = bookmarkService.addBibleBookmark(ordinalRange: range)
                    bookmark.sourcePromptId = context.promptId
                    if let suppliedNote = item.text.map(BibleUIAgentToolRequestParser.normalizeModelText),
                       !suppliedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bookmarkService.saveBibleBookmarkNote(
                            bookmarkId: bookmark.id,
                            note: suppliedNote,
                            defaultContentType: item.contentType.rawValue
                        )
                        bookmark.notes?.sourcePromptId = context.promptId
                    }
                    guard bookmarkService.assignLabel(
                        bookmarkId: bookmark.id,
                        labelId: Label.aiLabelId
                    ) != nil,
                    bookmarkService.assignLabel(
                        bookmarkId: bookmark.id,
                        labelId: label.id
                    ) != nil else {
                        bookmarkService.removeBibleBookmark(id: bookmark.id)
                        throw studyPadDomainError("ADD_ERROR", "The bookmark labels could not be saved.")
                    }
                    bookmarkService.updateBibleBookmarkToLabel(
                        bookmarkId: bookmark.id,
                        labelId: label.id,
                        orderNumber: index,
                        indentLevel: item.indentLevel,
                        expandContent: nil
                    )
                    bookmarkService.setPrimaryLabel(bookmarkId: bookmark.id, labelId: label.id)
                    if bookmark.notes?.sourcePromptId != nil {
                        bookmarkService.saveBibleBookmarkNote(
                            bookmarkId: bookmark.id,
                            note: bookmark.notes?.notes,
                            defaultContentType: item.contentType.rawValue
                        )
                    }
                    bookmarkCount += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BibleUIAgentDomainError {
                errors.append(studyPadItemError(index: index, item: item, message: error.message))
            } catch {
                errors.append(studyPadItemError(
                    index: index,
                    item: item,
                    message: "The item could not be created."
                ))
            }
        }

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("labelId", BibleUIAgentJSON.uuid(label.id)),
            ("labelName", .string(label.name)),
            ("itemsCreated", BibleUIAgentJSON.integer(textCount + bookmarkCount)),
            ("textEntries", BibleUIAgentJSON.integer(textCount)),
            ("bookmarkEntries", BibleUIAgentJSON.integer(bookmarkCount)),
            ("errors", .array(errors))
        ))
    }

    private func orderedStudyPadItems(labelID: UUID) -> [BibleUIAgentStudyPadEntryValue] {
        var values = bookmarkService.studyPadEntries(labelId: labelID).map {
            BibleUIAgentStudyPadEntryValue.text($0)
        }
        values.append(contentsOf: bookmarkService.bibleBookmarkToLabels(labelId: labelID).compactMap {
            guard let bookmark = $0.bookmark else { return nil }
            return BibleUIAgentStudyPadEntryValue.bible($0, bookmark)
        })
        values.append(contentsOf: bookmarkService.genericBookmarkToLabels(labelId: labelID).compactMap {
            guard let bookmark = $0.bookmark else { return nil }
            return BibleUIAgentStudyPadEntryValue.generic($0, bookmark)
        })
        return values.sorted { lhs, rhs in
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            if lhs.stableRank != rhs.stableRank { return lhs.stableRank < rhs.stableRank }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func fullStudyPadEntryJSON(_ item: BibleUIAgentStudyPadEntryValue) -> JSONValue {
        switch item {
        case .text(let entry):
            return BibleUIAgentJSON.object(
                ("type", .string("text")),
                ("id", BibleUIAgentJSON.uuid(entry.id)),
                ("orderNumber", BibleUIAgentJSON.integer(entry.orderNumber)),
                ("text", .string(entry.textEntry?.text ?? "")),
                ("contentType", .string(entry.contentType ?? BibleUIAgentNoteContentType.html.rawValue))
            )
        case .bible(let relation, let bookmark):
            let range = studyPadBookmarkReference(bookmark)
            return BibleUIAgentJSON.object(
                ("type", .string("bibleBookmark")),
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("orderNumber", BibleUIAgentJSON.integer(relation.orderNumber)),
                ("verseRange", BibleUIAgentJSON.string(range?.osis)),
                ("verseName", BibleUIAgentJSON.string(range?.name)),
                ("notes", BibleUIAgentJSON.string(bookmark.notes?.notes))
            )
        case .generic(let relation, let bookmark):
            return BibleUIAgentJSON.object(
                ("type", .string("genericBookmark")),
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("orderNumber", BibleUIAgentJSON.integer(relation.orderNumber)),
                ("book", .string(bookmark.bookInitials.isEmpty ? "unknown" : bookmark.bookInitials)),
                ("key", .string(bookmark.key)),
                ("notes", BibleUIAgentJSON.string(bookmark.notes?.notes))
            )
        }
    }

    private func indexStudyPadEntryJSON(
        _ item: BibleUIAgentStudyPadEntryValue,
        position: Int
    ) -> JSONValue {
        switch item {
        case .text(let entry):
            return BibleUIAgentJSON.object(
                ("type", .string("text")),
                ("id", BibleUIAgentJSON.uuid(entry.id)),
                ("position", BibleUIAgentJSON.integer(position)),
                ("preview", .string(studyPadPreview(entry.textEntry?.text)))
            )
        case .bible(_, let bookmark):
            let range = studyPadBookmarkReference(bookmark)
            return BibleUIAgentJSON.object(
                ("type", .string("bibleBookmark")),
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("position", BibleUIAgentJSON.integer(position)),
                ("verseRange", BibleUIAgentJSON.string(range?.osis)),
                ("verseName", BibleUIAgentJSON.string(range?.name)),
                ("hasNotes", .bool(bookmark.notes != nil))
            )
        case .generic(_, let bookmark):
            return BibleUIAgentJSON.object(
                ("type", .string("genericBookmark")),
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("position", BibleUIAgentJSON.integer(position)),
                ("book", .string(bookmark.bookInitials.isEmpty ? "unknown" : bookmark.bookInitials)),
                ("key", .string(bookmark.key)),
                ("hasNotes", .bool(bookmark.notes != nil))
            )
        }
    }

    private func studyPadPreview(_ text: String?) -> String {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let stripped = BibleUIAgentJSON.plainText(text)
        guard stripped.count > 80 else { return stripped }
        return String(stripped.prefix(80)) + "..."
    }

    private func studyPadItemError(
        index: Int,
        item: BibleUIAgentStudyPadItem,
        message: String
    ) -> JSONValue {
        BibleUIAgentJSON.object(
            ("index", BibleUIAgentJSON.integer(index)),
            ("type", .string(item.kind.rawValue)),
            ("message", .string(message))
        )
    }

    private func studyPadVerifiedRange(
        reference: String,
        activeBookInitials: String?
    ) throws -> VerifiedKJVAOrdinalRange {
        let verses = try BibleUIAgentKJVAReferenceParser.firstRange(reference)
        guard let first = verses.first, let last = verses.last else {
            throw studyPadDomainError("INVALID_REFERENCE", "Invalid verse reference: \(reference)")
        }
        guard let activeBookInitials,
              let module = swordManager.module(named: activeBookInitials),
              module.info.category == .bible else {
            guard let range = VerifiedKJVAOrdinalRange(
                sourceBookInitials: "KJVA",
                sourceVersification: JSwordKJVAVersification.name,
                sourceOrdinalStart: first.ordinal,
                sourceOrdinalEnd: last.ordinal,
                sourceReferenceStart: first.swordReference,
                sourceReferenceEnd: last.swordReference
            ) else {
                throw studyPadDomainError("INVALID_REFERENCE", "Invalid verse reference: \(reference)")
            }
            return range
        }
        guard let start = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: first.ordinal,
                  targetModule: module
              ), start.isAddressable,
              let end = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: last.ordinal,
                  targetModule: module
              ), end.isAddressable,
              let range = VerifiedKJVAOrdinalRange(
                  sourceBookInitials: module.info.name,
                  sourceVersification: VersificationMapper.versificationName(for: module),
                  sourceOrdinalStart: start.ordinal,
                  sourceOrdinalEnd: end.ordinal,
                  sourceReferenceStart: VerseKeyReference(
                      osisBookId: start.reference.osisBookId,
                      chapter: start.reference.chapter,
                      verse: start.reference.verse,
                      ordinal: start.ordinal
                  ),
                  sourceReferenceEnd: VerseKeyReference(
                      osisBookId: end.reference.osisBookId,
                      chapter: end.reference.chapter,
                      verse: end.reference.verse,
                      ordinal: end.ordinal
                  )
              ) else {
            throw studyPadDomainError(
                "INVALID_REFERENCE",
                "The verse reference is not addressable in \(activeBookInitials)."
            )
        }
        return range
    }

    private func studyPadBookmarkReference(
        _ bookmark: BibleBookmark
    ) -> (osis: String, name: String)? {
        guard let start = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalStart),
              let end = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalEnd) else {
            return nil
        }
        let startName = "\(JSwordKJVAVersification.localizedLongBookName(osisId: start.osisId) ?? start.osisId) \(start.chapter):\(start.verse)"
        if start.ordinal == end.ordinal { return (start.osisRef, startName) }
        let endName = start.osisId == end.osisId && start.chapter == end.chapter
            ? String(end.verse)
            : "\(JSwordKJVAVersification.localizedLongBookName(osisId: end.osisId) ?? end.osisId) \(end.chapter):\(end.verse)"
        return ("\(start.osisRef)-\(end.osisRef)", "\(startName)-\(endName)")
    }

    private func uniqueStudyPadName(_ baseName: String, existingNames: [String]) -> String {
        let names = Set(existingNames.map { $0.lowercased() })
        guard names.contains(baseName.lowercased()) else { return baseName }
        var suffix = 2
        while names.contains("\(baseName) (\(suffix))".lowercased()) { suffix += 1 }
        return "\(baseName) (\(suffix))"
    }

    private func studyPadDomainError(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
