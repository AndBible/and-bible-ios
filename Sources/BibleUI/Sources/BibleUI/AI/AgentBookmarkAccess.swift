// AgentBookmarkAccess.swift -- Android-compatible bookmark and label AI operations

import BibleCore
import Foundation
import SwordKit

@MainActor
extension BibleUIAgentDomainAdapter {
    /** Returns Bible bookmarks overlapping Android's first parsed KJVA range. */
    func getBookmarksForVerse(reference: String) throws -> AgentToolResult {
        let verses = try BibleUIAgentKJVAReferenceParser.firstRange(reference)
        guard let first = verses.first, let last = verses.last else {
            throw bookmarkDomainError("INVALID_REFERENCE", "The verse reference is invalid.")
        }

        let bookmarks = bookmarkService.bookmarks(
            for: first.ordinal,
            endOrdinal: last.ordinal
        ).sorted(by: bibleBookmarkOrder)
        guard bookmarks.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw bookmarkDomainError(
                "LIMIT_EXCEEDED",
                "Too many bookmarks matched the requested passage."
            )
        }

        let values = bookmarks.compactMap { bookmark -> JSONValue? in
            guard let range = bookmarkReference(bookmark) else { return nil }
            let labels = orderedLabels(for: bookmark).map { label in
                BibleUIAgentJSON.object(
                    ("id", BibleUIAgentJSON.uuid(label.id)),
                    ("name", .string(label.name))
                )
            }
            return BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("verseRange", .string(range.osis)),
                ("verseName", .string(range.name)),
                ("notes", BibleUIAgentJSON.string(bookmark.notes?.notes)),
                ("createdAt", BibleUIAgentJSON.milliseconds(bookmark.createdAt)),
                ("lastUpdatedOn", BibleUIAgentJSON.milliseconds(bookmark.lastUpdatedOn)),
                ("labels", .array(labels))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("verseRef", .string(reference)),
            ("bookmarkCount", BibleUIAgentJSON.integer(values.count)),
            ("bookmarks", .array(values))
        ))
    }

    /** Returns the Android Bible-first, generic-second projection for one label. */
    func getBookmarksWithLabel(
        labelID: UUID,
        maximum: Int,
        fields: Set<BibleUIAgentBookmarkField>
    ) throws -> AgentToolResult {
        guard let label = bookmarkService.label(id: labelID) else {
            throw bookmarkDomainError("LABEL_NOT_FOUND", "Label not found: \(labelID.uuidString.lowercased())")
        }

        var values: [JSONValue] = []
        for bookmark in bookmarkService.bibleBookmarks(withLabel: labelID).sorted(by: bibleBookmarkOrder) {
            guard values.count < maximum, let range = bookmarkReference(bookmark) else { continue }
            values.append(BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                ("type", .string("bible")),
                ("verseRange", fields.contains(.verseRange) ? .string(range.osis) : nil),
                ("verseName", fields.contains(.verseName) ? .string(range.name) : nil),
                ("notes", fields.contains(.notes) ? BibleUIAgentJSON.string(bookmark.notes?.notes) : nil),
                ("createdAt", fields.contains(.createdAt)
                    ? BibleUIAgentJSON.milliseconds(bookmark.createdAt)
                    : nil),
                ("book", nil),
                ("key", nil)
            ))
        }
        if values.count < maximum {
            for bookmark in bookmarkService.genericBookmarks(withLabel: labelID).sorted(by: genericBookmarkOrder) {
                guard values.count < maximum else { break }
                values.append(BibleUIAgentJSON.object(
                    ("id", BibleUIAgentJSON.uuid(bookmark.id)),
                    ("type", .string("generic")),
                    ("verseRange", nil),
                    ("verseName", nil),
                    ("notes", fields.contains(.notes) ? BibleUIAgentJSON.string(bookmark.notes?.notes) : nil),
                    ("createdAt", fields.contains(.createdAt)
                        ? BibleUIAgentJSON.milliseconds(bookmark.createdAt)
                        : nil),
                    ("book", .string(bookmark.bookInitials.isEmpty ? "unknown" : bookmark.bookInitials)),
                    ("key", .string(bookmark.key))
                ))
            }
        }

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("labelId", BibleUIAgentJSON.uuid(labelID)),
            ("labelName", .string(label.name)),
            ("bookmarkCount", BibleUIAgentJSON.integer(values.count)),
            ("bookmarks", .array(values))
        ))
    }

    /** Lists user labels in Android's case-insensitive name order. */
    func getAllLabels() throws -> AgentToolResult {
        let labels = bookmarkService.allLabels()
            .filter(\.isRealLabel)
            .sorted(by: labelNameOrder)
        guard labels.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw bookmarkDomainError("LIMIT_EXCEEDED", "Too many labels were returned.")
        }
        let values = labels.map { label in
            BibleUIAgentJSON.object(
                ("id", BibleUIAgentJSON.uuid(label.id)),
                ("name", .string(label.name)),
                ("color", BibleUIAgentJSON.integer(label.color)),
                ("isFavourite", .bool(label.favourite))
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("labelCount", BibleUIAgentJSON.integer(values.count)),
            ("labels", .array(values))
        ))
    }

    /** Creates a verified KJVA bookmark and applies Android's AI ownership metadata. */
    func createBookmark(
        reference: String,
        note: String?,
        contentType: BibleUIAgentNoteContentType,
        labelIDs: [UUID],
        primaryLabelID: UUID?,
        bookInitials: String?,
        startOffset: Int?,
        endOffset: Int?,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        let requestedLabels = Array(Set(labelIDs)).sorted { $0.uuidString < $1.uuidString }
        for labelID in requestedLabels where bookmarkService.label(id: labelID) == nil {
            throw bookmarkDomainError(
                "LABEL_NOT_FOUND",
                "Label not found: \(labelID.uuidString.lowercased())"
            )
        }
        let verifiedRange = try verifiedBookmarkRange(
            reference: reference,
            requestedBookInitials: bookInitials ?? context.activeDocumentInitials
        )
        let hasOffsets = startOffset != nil && endOffset != nil
        let bookmark = bookmarkService.addBibleBookmark(
            ordinalRange: verifiedRange,
            wholeVerse: !hasOffsets,
            startOffset: startOffset,
            endOffset: endOffset
        )
        bookmark.sourcePromptId = context.promptId

        let normalizedNote = note.map(BibleUIAgentToolRequestParser.normalizeModelText)
        if let normalizedNote,
           !normalizedNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bookmarkService.saveBibleBookmarkNote(
                bookmarkId: bookmark.id,
                note: normalizedNote,
                defaultContentType: contentType.rawValue
            )
            bookmark.notes?.sourcePromptId = context.promptId
        }

        bookmarkService.ensureSystemLabels()
        let allLabelIDs = Set(requestedLabels + [Label.aiLabelId])
        for labelID in allLabelIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard bookmarkService.assignLabel(bookmarkId: bookmark.id, labelId: labelID) != nil else {
                bookmarkService.removeBibleBookmark(id: bookmark.id)
                throw bookmarkDomainError("CREATE_ERROR", "The bookmark labels could not be saved.")
            }
        }
        if let desiredPrimary = primaryLabelID ?? labelIDs.first {
            bookmarkService.setPrimaryLabel(bookmarkId: bookmark.id, labelId: desiredPrimary)
        }
        if bookmark.notes?.sourcePromptId != nil {
            bookmarkService.saveBibleBookmarkNote(
                bookmarkId: bookmark.id,
                note: bookmark.notes?.notes,
                defaultContentType: contentType.rawValue
            )
        }

        guard let range = bookmarkReference(bookmark) else {
            bookmarkService.removeBibleBookmark(id: bookmark.id)
            throw bookmarkDomainError("CREATE_ERROR", "The bookmark reference could not be verified.")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("id", BibleUIAgentJSON.uuid(bookmark.id)),
            ("verseRef", .string(range.osis)),
            ("verseName", .string(range.name)),
            ("hasNote", .bool(normalizedNote != nil)),
            ("labelCount", BibleUIAgentJSON.integer(allLabelIDs.count))
        ))
    }

    /** Adds a first AI-owned note to either bookmark table. */
    func addBookmarkNote(
        bookmarkID: UUID,
        note: String,
        contentType: BibleUIAgentNoteContentType,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        let normalized = BibleUIAgentToolRequestParser.normalizeModelText(note)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw bookmarkDomainError("INVALID_ARGS", "Missing required parameter: note")
        }
        let target = try bookmarkTarget(bookmarkID)
        guard target.note == nil else {
            throw bookmarkDomainError(
                "NOTE_EXISTS",
                "Bookmark already has a note. Use updateBookmarkNote to modify it."
            )
        }

        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: bookmarkID,
            note: normalized,
            defaultContentType: contentType.rawValue
        )
        setBookmarkNotePromptID(bookmarkID, promptID: context.promptId)
        try ensureAIAssignment(bookmarkID)
        persistBookmarkNote(bookmarkID, contentType: contentType.rawValue)

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("bookmarkId", BibleUIAgentJSON.uuid(bookmarkID)),
            ("noteLength", BibleUIAgentJSON.integer(normalized.utf16.count)),
            ("contentType", .string(contentType.rawValue))
        ))
    }

    /** Replaces an existing or absent bookmark note without crossing bookmark tables. */
    func updateBookmarkNote(
        bookmarkID: UUID,
        note: String,
        context: AgentExecutionContext
    ) throws -> AgentToolResult {
        let normalized = BibleUIAgentToolRequestParser.normalizeModelText(note)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw bookmarkDomainError("INVALID_ARGS", "Missing required parameter: note")
        }
        let target = try bookmarkTarget(bookmarkID)
        let previousLength = target.note?.utf16.count ?? 0
        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: bookmarkID,
            note: normalized,
            defaultContentType: BibleUIAgentNoteContentType.markdown.rawValue
        )
        setBookmarkNotePromptID(bookmarkID, promptID: context.promptId)
        try ensureAIAssignment(bookmarkID)
        persistBookmarkNote(bookmarkID, contentType: BibleUIAgentNoteContentType.markdown.rawValue)

        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("bookmarkId", BibleUIAgentJSON.uuid(bookmarkID)),
            ("noteLength", BibleUIAgentJSON.integer(normalized.utf16.count)),
            ("previousNoteLength", BibleUIAgentJSON.integer(previousLength))
        ))
    }

    /** Creates one uniquely named user label. */
    func createLabel(name: String, color: Int?) throws -> AgentToolResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw bookmarkDomainError("INVALID_ARGS", "Missing required parameter: name")
        }
        let uniqueName = uniqueLabelName(
            trimmed,
            existingNames: bookmarkService.allLabels().map(\.name)
        )
        let label = bookmarkService.createLabel(
            name: uniqueName,
            color: color.flatMap { $0 == 0 ? nil : $0 } ?? Label.defaultColor
        )
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("id", BibleUIAgentJSON.uuid(label.id)),
            ("name", .string(label.name)),
            ("color", BibleUIAgentJSON.integer(label.color))
        ))
    }

    /** Attaches a previously unassigned label to a Bible or generic bookmark. */
    func addLabelToBookmark(bookmarkID: UUID, labelID: UUID) throws -> AgentToolResult {
        _ = try bookmarkTarget(bookmarkID)
        guard let label = bookmarkService.label(id: labelID) else {
            throw bookmarkDomainError("LABEL_NOT_FOUND", "Label not found: \(labelID.uuidString.lowercased())")
        }
        guard !bookmarkHasLabel(bookmarkID, labelID: labelID) else {
            throw bookmarkDomainError("ALREADY_LINKED", "Bookmark already has this label")
        }
        guard bookmarkService.assignLabel(bookmarkId: bookmarkID, labelId: labelID) != nil else {
            throw bookmarkDomainError("ADD_ERROR", "The label could not be added to the bookmark.")
        }
        return try bookmarkLabelMutationResult(bookmarkID: bookmarkID, label: label)
    }

    /** Deletes one Bible or generic bookmark after resolving its Android display identity. */
    func deleteBookmark(bookmarkID: UUID) throws -> AgentToolResult {
        let verseName: String
        if let bookmark = bookmarkService.bibleBookmark(id: bookmarkID) {
            verseName = bookmarkReference(bookmark)?.name ?? bookmarkID.uuidString.lowercased()
            bookmarkService.removeBibleBookmark(id: bookmarkID)
        } else if bookmarkService.genericBookmark(id: bookmarkID) != nil {
            verseName = bookmarkID.uuidString.lowercased()
            bookmarkService.removeGenericBookmark(id: bookmarkID)
        } else {
            throw bookmarkDomainError(
                "BOOKMARK_NOT_FOUND",
                "Bookmark not found: \(bookmarkID.uuidString.lowercased())"
            )
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("bookmarkId", BibleUIAgentJSON.uuid(bookmarkID)),
            ("verseName", .string(verseName))
        ))
    }

    /** Deletes a non-system label and optionally removes bookmarks it alone owned. */
    func deleteLabel(labelID: UUID, deleteOrphanedBookmarks: Bool) throws -> AgentToolResult {
        guard let label = bookmarkService.label(id: labelID) else {
            throw bookmarkDomainError("LABEL_NOT_FOUND", "Label not found: \(labelID.uuidString.lowercased())")
        }
        guard !label.isSystemLabel else {
            throw bookmarkDomainError(
                "SPECIAL_LABEL",
                "Cannot delete special internal label: \(label.name)"
            )
        }
        do {
            try labelConfigurationService.deleteLabel(
                id: labelID,
                deleteOrphanedBookmarks: deleteOrphanedBookmarks
            )
        } catch WorkspaceLabelConfigurationError.labelNotFound {
            throw bookmarkDomainError("LABEL_NOT_FOUND", "Label not found: \(labelID.uuidString.lowercased())")
        }
        return try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("labelId", BibleUIAgentJSON.uuid(labelID)),
            ("labelName", .string(label.name)),
            ("deletedOrphanedBookmarks", .bool(deleteOrphanedBookmarks))
        ))
    }

    /** Removes an existing bookmark-label relationship without deleting either entity. */
    func removeLabelFromBookmark(bookmarkID: UUID, labelID: UUID) throws -> AgentToolResult {
        _ = try bookmarkTarget(bookmarkID)
        guard let label = bookmarkService.label(id: labelID) else {
            throw bookmarkDomainError("LABEL_NOT_FOUND", "Label not found: \(labelID.uuidString.lowercased())")
        }
        guard bookmarkHasLabel(bookmarkID, labelID: labelID) else {
            throw bookmarkDomainError("NOT_LINKED", "Bookmark does not have this label")
        }
        bookmarkService.removeLabel(bookmarkId: bookmarkID, labelId: labelID)
        return try bookmarkLabelMutationResult(bookmarkID: bookmarkID, label: label)
    }

    private struct BookmarkNoteTarget {
        let note: String?
    }

    private func bookmarkTarget(_ id: UUID) throws -> BookmarkNoteTarget {
        if let bookmark = bookmarkService.bibleBookmark(id: id) {
            return BookmarkNoteTarget(note: bookmark.notes?.notes)
        }
        if let bookmark = bookmarkService.genericBookmark(id: id) {
            return BookmarkNoteTarget(note: bookmark.notes?.notes)
        }
        throw bookmarkDomainError(
            "BOOKMARK_NOT_FOUND",
            "Bookmark not found: \(id.uuidString.lowercased())"
        )
    }

    private func setBookmarkNotePromptID(_ id: UUID, promptID: UUID) {
        if let bookmark = bookmarkService.bibleBookmark(id: id) {
            bookmark.notes?.sourcePromptId = promptID
        } else {
            bookmarkService.genericBookmark(id: id)?.notes?.sourcePromptId = promptID
        }
    }

    private func persistBookmarkNote(_ id: UUID, contentType: String) {
        let note = bookmarkService.bibleBookmark(id: id)?.notes?.notes
            ?? bookmarkService.genericBookmark(id: id)?.notes?.notes
        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: id,
            note: note,
            defaultContentType: contentType
        )
    }

    private func ensureAIAssignment(_ bookmarkID: UUID) throws {
        bookmarkService.ensureSystemLabels()
        guard bookmarkService.assignLabel(bookmarkId: bookmarkID, labelId: Label.aiLabelId) != nil else {
            throw bookmarkDomainError("ADD_ERROR", "The AI label could not be saved.")
        }
    }

    private func bookmarkHasLabel(_ bookmarkID: UUID, labelID: UUID) -> Bool {
        bookmarkService.bibleBookmarkToLabel(bookmarkId: bookmarkID, labelId: labelID) != nil
            || bookmarkService.genericBookmarkToLabel(bookmarkId: bookmarkID, labelId: labelID) != nil
    }

    private func bookmarkLabelMutationResult(
        bookmarkID: UUID,
        label: Label
    ) throws -> AgentToolResult {
        try BibleUIAgentJSON.success(BibleUIAgentJSON.object(
            ("bookmarkId", BibleUIAgentJSON.uuid(bookmarkID)),
            ("labelId", BibleUIAgentJSON.uuid(label.id)),
            ("labelName", .string(label.name))
        ))
    }

    private func verifiedBookmarkRange(
        reference: String,
        requestedBookInitials: String?
    ) throws -> VerifiedKJVAOrdinalRange {
        let verses = try BibleUIAgentKJVAReferenceParser.firstRange(reference)
        guard let first = verses.first, let last = verses.last else {
            throw bookmarkDomainError("INVALID_REFERENCE", "The verse reference is invalid.")
        }
        guard let requestedBookInitials,
              let module = swordManager.module(named: requestedBookInitials),
              module.info.category == .bible else {
            guard let range = VerifiedKJVAOrdinalRange(
                sourceBookInitials: requestedBookInitials ?? "KJVA",
                sourceVersification: JSwordKJVAVersification.name,
                sourceOrdinalStart: first.ordinal,
                sourceOrdinalEnd: last.ordinal,
                sourceReferenceStart: first.swordReference,
                sourceReferenceEnd: last.swordReference
            ) else {
                throw bookmarkDomainError("INVALID_REFERENCE", "The verse reference could not be mapped.")
            }
            return range
        }

        guard let sourceStart = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: first.ordinal,
                  targetModule: module
              ), sourceStart.isAddressable,
              let sourceEnd = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: last.ordinal,
                  targetModule: module
              ), sourceEnd.isAddressable,
              sourceEnd.ordinal >= sourceStart.ordinal,
              let range = VerifiedKJVAOrdinalRange(
                  sourceBookInitials: module.info.name,
                  sourceVersification: VersificationMapper.versificationName(for: module),
                  sourceOrdinalStart: sourceStart.ordinal,
                  sourceOrdinalEnd: sourceEnd.ordinal,
                  sourceReferenceStart: VerseKeyReference(
                      osisBookId: sourceStart.reference.osisBookId,
                      chapter: sourceStart.reference.chapter,
                      verse: sourceStart.reference.verse,
                      ordinal: sourceStart.ordinal
                  ),
                  sourceReferenceEnd: VerseKeyReference(
                      osisBookId: sourceEnd.reference.osisBookId,
                      chapter: sourceEnd.reference.chapter,
                      verse: sourceEnd.reference.verse,
                      ordinal: sourceEnd.ordinal
                  )
              ) else {
            throw bookmarkDomainError(
                "INVALID_REFERENCE",
                "The verse reference is not addressable in \(requestedBookInitials)."
            )
        }
        return range
    }

    private func bookmarkReference(_ bookmark: BibleBookmark) -> (osis: String, name: String)? {
        guard let start = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalStart),
              let end = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalEnd) else {
            return nil
        }
        let startName = "\(JSwordKJVAVersification.localizedLongBookName(osisId: start.osisId) ?? start.osisId) \(start.chapter):\(start.verse)"
        guard start.ordinal != end.ordinal else { return (start.osisRef, startName) }
        let endName: String
        if start.osisId == end.osisId, start.chapter == end.chapter {
            endName = String(end.verse)
        } else if start.osisId == end.osisId {
            endName = "\(end.chapter):\(end.verse)"
        } else {
            endName = "\(JSwordKJVAVersification.localizedLongBookName(osisId: end.osisId) ?? end.osisId) \(end.chapter):\(end.verse)"
        }
        return ("\(start.osisRef)-\(end.osisRef)", "\(startName)-\(endName)")
    }

    private func orderedLabels(for bookmark: BibleBookmark) -> [Label] {
        (bookmark.bookmarkToLabels ?? [])
            .compactMap(\.label)
            .sorted(by: labelNameOrder)
    }

    private func orderedLabels(for bookmark: GenericBookmark) -> [Label] {
        (bookmark.bookmarkToLabels ?? [])
            .compactMap(\.label)
            .sorted(by: labelNameOrder)
    }

    private func uniqueLabelName(_ baseName: String, existingNames: [String]) -> String {
        let names = Set(existingNames.map { $0.lowercased() })
        guard names.contains(baseName.lowercased()) else { return baseName }
        var suffix = 2
        while names.contains("\(baseName) (\(suffix))".lowercased()) {
            suffix += 1
        }
        return "\(baseName) (\(suffix))"
    }

    private func labelNameOrder(_ lhs: Label, _ rhs: Label) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func bibleBookmarkOrder(_ lhs: BibleBookmark, _ rhs: BibleBookmark) -> Bool {
        if lhs.kjvOrdinalStart != rhs.kjvOrdinalStart {
            return lhs.kjvOrdinalStart < rhs.kjvOrdinalStart
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func genericBookmarkOrder(_ lhs: GenericBookmark, _ rhs: GenericBookmark) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func bookmarkDomainError(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
