// AgentToolArgumentValidation.swift -- Strict bounded decoding for agent tool calls

import BibleCore
import Foundation

/**
 Strict decoder for provider-neutral tool argument objects.

 The decoder mirrors Android defaults and clamping where intentional, rejects malformed UUIDs and
 non-integral numbers, and applies conservative request-size limits before domain I/O.
 */
public enum BibleUIAgentToolRequestParser {
    public static let maximumTextCharacters = 200_000
    public static let maximumQueryCharacters = 2_000
    public static let maximumIdentifierCharacters = 512
    public static let maximumArrayItems = 500
    public static let maximumStudyPadItems = 200

    /**
     Decodes one registered tool call into its typed request.

     - Parameters:
       - tool: Registered Android tool identity.
       - arguments: Provider-decoded JSON object.
     - Returns: Fully typed and coarsely bounded request.
     - Side effects: None.
     - Failure modes: Throws BibleUIAgentArgumentError for missing, mistyped, malformed, or
       oversized values.
     */
    public static func parse(
        tool: AgentTool,
        arguments: [String: JSONValue]
    ) throws -> BibleUIAgentToolRequest {
        let reader = AgentArgumentReader(arguments)
        try reader.validateTaskCompletionFields()

        switch tool {
        case .getVerseContent:
            return .getVerseContent(
                book: try reader.requiredString("book"),
                verseReference: try reader.requiredString("verseRef"),
                format: try reader.enumeration("format", default: .text)
            )
        case .searchBible:
            return .searchBible(
                query: try reader.requiredString("query", maximum: maximumQueryCharacters),
                books: try reader.stringArray("books", default: []),
                maximumResults: min(max(try reader.integer("maxResults", default: 50), 1), 500),
                offset: max(try reader.integer("offset", default: 0), 0)
            )
        case .searchByStrongs:
            let supplied = try reader.requiredString("strongsNumber", maximum: 32)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .searchByStrongs(
                reportedNumber: supplied.uppercased(),
                canonicalToken: try normalizedStrongs(supplied),
                book: try reader.optionalString("book"),
                maximumResults: min(max(try reader.integer("maxResults", default: 50), 1), 500),
                offset: max(try reader.integer("offset", default: 0), 0)
            )
        case .getCommentaries:
            return .getCommentaries(
                verseReference: try reader.requiredString("verseRef"),
                commentaries: try reader.stringArray("commentaries", default: []),
                format: try reader.enumeration("format", default: .text)
            )
        case .getDictionaryEntry:
            return .getDictionaryEntry(
                dictionary: try reader.requiredString("dictionary"),
                key: try reader.requiredString("key"),
                format: try reader.enumeration("format", default: .text)
            )
        case .getBookmarksForVerse:
            return .getBookmarksForVerse(verseReference: try reader.requiredString("verseRef"))
        case .getBookmarksWithLabel:
            let defaultFields: Set<BibleUIAgentBookmarkField> = [
                .verseRange, .verseName, .createdAt,
            ]
            return .getBookmarksWithLabel(
                labelID: try reader.requiredUUID("labelId"),
                maximumResults: min(max(try reader.integer("maxResults", default: 100), 1), 500),
                fields: try reader.enumerationSet("fields", default: defaultFields)
            )
        case .getAllLabels:
            return .getAllLabels
        case .getStudyPadContent:
            return .getStudyPadContent(
                labelID: try reader.requiredUUID("labelId"),
                mode: try reader.enumeration("mode", default: .full),
                offset: max(try reader.integer("offset", default: 0), 0),
                limit: min(max(try reader.integer("limit", default: 20), 1), 200)
            )
        case .searchStudyPads:
            return .searchStudyPads(
                query: try reader.requiredString("query", maximum: maximumQueryCharacters)
            )
        case .getInstalledDocuments:
            return .getInstalledDocuments(category: try reader.optionalEnumeration("category"))
        case .getMyDocuments:
            return .getMyDocuments
        case .getMyDocumentPages:
            let documentID = try reader.optionalUUID("documentId")
            let initials = try reader.optionalString("initials")
            guard documentID != nil || initials != nil else {
                throw BibleUIAgentArgumentError(
                    message: "One of documentId or initials is required"
                )
            }
            return .getMyDocumentPages(
                documentID: documentID,
                initials: initials,
                includeContent: try reader.boolean("includeContent", default: false)
            )
        case .getGenBookKeys:
            return .getGenBookKeys(
                book: try reader.requiredString("book"),
                offset: max(try reader.integer("offset", default: 0), 0),
                limit: min(max(try reader.integer("limit", default: 100), 1), 500)
            )
        case .getGenBookContent:
            return .getGenBookContent(
                book: try reader.requiredString("book"),
                key: try reader.requiredString("key"),
                format: try reader.enumeration("format", default: .text)
            )
        case .getWindows:
            return .getWindows
        case .createBookmark:
            return try createBookmarkRequest(reader)
        case .addBookmarkNote:
            return .addBookmarkNote(
                bookmarkID: try reader.requiredUUID("bookmarkId"),
                note: try reader.requiredString("note", maximum: maximumTextCharacters),
                contentType: try reader.enumeration("contentType", default: .markdown)
            )
        case .updateBookmarkNote:
            return .updateBookmarkNote(
                bookmarkID: try reader.requiredUUID("bookmarkId"),
                note: try reader.requiredString("note", maximum: maximumTextCharacters)
            )
        case .createLabel:
            return .createLabel(
                name: try reader.requiredString("name", maximum: 500),
                color: try reader.optionalInteger("color")
            )
        case .addLabelToBookmark:
            return .addLabelToBookmark(
                bookmarkID: try reader.requiredUUID("bookmarkId"),
                labelID: try reader.requiredUUID("labelId")
            )
        case .deleteBookmark:
            return .deleteBookmark(bookmarkID: try reader.requiredUUID("bookmarkId"))
        case .deleteLabel:
            return .deleteLabel(
                labelID: try reader.requiredUUID("labelId"),
                deleteOrphanedBookmarks: try reader.boolean(
                    "deleteOrphanedBookmarks",
                    default: false
                )
            )
        case .removeLabelFromBookmark:
            return .removeLabelFromBookmark(
                bookmarkID: try reader.requiredUUID("bookmarkId"),
                labelID: try reader.requiredUUID("labelId")
            )
        case .addStudyPadEntry:
            let suppliedOrderNumber = try reader.optionalNonnegativeInteger("orderNumber")
            return .addStudyPadEntry(
                labelID: try reader.requiredUUID("labelId"),
                text: try reader.requiredString("text", maximum: maximumTextCharacters),
                contentType: try reader.enumeration("contentType", default: .markdown),
                orderNumber: suppliedOrderNumber == 0 ? nil : suppliedOrderNumber
            )
        case .updateStudyPadTextEntry:
            return .updateStudyPadTextEntry(
                entryID: try reader.requiredUUID("entryId"),
                text: try reader.requiredString("text", maximum: maximumTextCharacters)
            )
        case .createStudyPad:
            return .createStudyPad(
                name: try reader.requiredString("name", maximum: 500),
                color: try reader.optionalInteger("color"),
                items: try studyPadItems(reader)
            )
        case .createMyDocument:
            return .createMyDocument(
                name: try reader.requiredString("name", maximum: 500),
                description: try reader.optionalString(
                    "description",
                    maximum: 20_000,
                    preservesBlank: true
                )
            )
        case .addMyDocumentPage:
            return .addMyDocumentPage(
                documentID: try reader.optionalUUID("documentId"),
                initials: try reader.optionalString("initials"),
                title: try reader.requiredString("title", maximum: 2_000),
                content: try reader.requiredString("content", maximum: maximumTextCharacters),
                contentType: try reader.enumeration("contentType", default: .markdown)
            )
        case .editMyDocumentPage:
            return try editMyDocumentPageRequest(reader)
        case .deleteMyDocumentPage:
            return .deleteMyDocumentPage(pageID: try reader.requiredUUID("pageId"))
        case .createWindow:
            return .createWindow(
                documentInitials: try reader.optionalString("documentInitials"),
                key: try reader.optionalString("key"),
                minimized: try reader.boolean("minimized", default: false)
            )
        case .manageWindow:
            return .manageWindow(
                windowID: try reader.requiredUUID("windowId"),
                action: try reader.requiredEnumeration("action")
            )
        case .setWindowDocument:
            return .setWindowDocument(
                windowID: try reader.optionalUUID("windowId"),
                documentInitials: try reader.requiredString("documentInitials"),
                key: try reader.optionalString("key")
            )
        case .setDocumentTitle:
            let stripped = stripMarkdown(
                from: try reader.requiredString("title", maximum: 2_000)
            )
            guard !stripped.isEmpty else {
                throw BibleUIAgentArgumentError(message: "title must contain plain text")
            }
            return .setDocumentTitle(title: String(stripped.prefix(80)))
        case .finishWithStudyPad:
            return .finishWithStudyPad(
                labelID: try reader.requiredUUID("labelId"),
                scrollToEntryID: try reader.optionalUUID("scrollToEntryId"),
                message: try reader.requiredStringPreservingBlank("message", maximum: 10_000)
            )
        case .finishWithMyDocumentPage:
            return .finishWithMyDocumentPage(
                pageID: try reader.requiredUUID("pageId"),
                message: try reader.requiredStringPreservingBlank("message", maximum: 10_000)
            )
        case .finishWithoutDocument:
            return .finishWithoutDocument(
                message: try reader.requiredStringPreservingBlank("message", maximum: 10_000)
            )
        }
    }

    /** Replaces only Android's escaped newline and tab sequences in model-authored text. */
    public static func normalizeModelText(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    /** Removes Markdown title syntax using Android's production normalization order. */
    public static func stripMarkdown(from value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^\)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        for marker in ["**", "__", "*", "_", "\u{0060}", "#"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func createBookmarkRequest(
        _ reader: AgentArgumentReader
    ) throws -> BibleUIAgentToolRequest {
        let startOffset = try reader.optionalNonnegativeInteger("startOffset")
        let endOffset = try reader.optionalNonnegativeInteger("endOffset")
        guard (startOffset == nil) == (endOffset == nil) else {
            throw BibleUIAgentArgumentError(
                message: "startOffset and endOffset must be provided together"
            )
        }
        if let startOffset, let endOffset, endOffset < startOffset {
            throw BibleUIAgentArgumentError(message: "endOffset must not precede startOffset")
        }
        let labelIDs = try reader.uuidArray("labelIds", default: [])
        let primaryLabelID = try reader.optionalUUID("primaryLabelId")
        if let primaryLabelID, !labelIDs.contains(primaryLabelID) {
            throw BibleUIAgentArgumentError(
                message: "primaryLabelId must be present in labelIds"
            )
        }
        return .createBookmark(
            verseReference: try reader.requiredString("verseRef"),
            note: try reader.optionalString(
                "note",
                maximum: maximumTextCharacters,
                preservesBlank: true
            ),
            noteContentType: try reader.enumeration("noteContentType", default: .markdown),
            labelIDs: labelIDs,
            primaryLabelID: primaryLabelID,
            bookInitials: try reader.optionalString("bookInitials"),
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    private static func editMyDocumentPageRequest(
        _ reader: AgentArgumentReader
    ) throws -> BibleUIAgentToolRequest {
        let title = try reader.optionalString(
            "title",
            maximum: 2_000,
            preservesBlank: true
        )
        let content = try reader.optionalString(
            "content",
            maximum: maximumTextCharacters,
            preservesBlank: true
        )
        let orderNumber = try reader.optionalNonnegativeInteger("orderNumber")
        guard title != nil || content != nil || orderNumber != nil else {
            throw BibleUIAgentArgumentError(
                message: "At least one of title, content, or orderNumber is required"
            )
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BibleUIAgentArgumentError(message: "title must not be blank")
        }
        return .editMyDocumentPage(
            pageID: try reader.requiredUUID("pageId"),
            title: title,
            content: content,
            orderNumber: orderNumber
        )
    }

    private static func normalizedStrongs(_ value: String) throws -> String {
        guard let prefix = value.first, "HhGg".contains(prefix) else {
            throw BibleUIAgentArgumentError(
                code: "INVALID_STRONGS",
                message: "strongsNumber must use an H or G prefix"
            )
        }
        let digits = value.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            throw BibleUIAgentArgumentError(
                code: "INVALID_STRONGS",
                message: "strongsNumber must contain decimal digits"
            )
        }
        let trimmed = digits.drop(while: { $0 == "0" })
        return String(prefix).lowercased() + (trimmed.isEmpty ? "0" : String(trimmed))
    }

    private static func studyPadItems(
        _ reader: AgentArgumentReader
    ) throws -> [BibleUIAgentStudyPadItem] {
        let objects = try reader.objectArray("items")
        guard !objects.isEmpty else {
            throw BibleUIAgentArgumentError(
                code: "EMPTY_ITEMS",
                message: "items must not be empty"
            )
        }
        guard objects.count <= maximumStudyPadItems else {
            throw BibleUIAgentArgumentError(
                code: "LIMIT_EXCEEDED",
                message: "items exceeds the maximum count"
            )
        }
        return try objects.map { object in
            let item = AgentArgumentReader(object)
            let kind: BibleUIAgentStudyPadItem.Kind = try item.requiredEnumeration("type")
            let text = try item.optionalString(
                "text",
                maximum: maximumTextCharacters,
                preservesBlank: true
            )
            let verseReference = try item.optionalString("verseRef")
            return BibleUIAgentStudyPadItem(
                kind: kind,
                text: text,
                verseReference: verseReference,
                indentLevel: try item.integer(
                    "indentLevel",
                    default: 0,
                    range: 0...3
                ),
                contentType: try item.enumeration("contentType", default: .markdown)
            )
        }
    }
}

/** Strict accessor that keeps JSON type checks in one auditable boundary. */
private struct AgentArgumentReader {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func validateTaskCompletionFields() throws {
        if let value = values["taskComplete"], case .bool = value {
            // Valid optional completion signal.
        } else if values["taskComplete"] != nil {
            throw BibleUIAgentArgumentError(message: "taskComplete must be a boolean")
        }
        if let value = values["taskCompleteMessage"], case .string = value {
            // Valid optional completion message.
        } else if values["taskCompleteMessage"] != nil {
            throw BibleUIAgentArgumentError(
                message: "taskCompleteMessage must be a string"
            )
        }
    }

    func requiredString(
        _ key: String,
        maximum: Int = BibleUIAgentToolRequestParser.maximumIdentifierCharacters
    ) throws -> String {
        guard let value = try optionalString(
            key,
            maximum: maximum,
            preservesBlank: true
        ), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleUIAgentArgumentError(
                message: "Missing required parameter: \(key)"
            )
        }
        return value
    }

    /** Requires a string property while preserving Android's blank terminal-message fallback. */
    func requiredStringPreservingBlank(
        _ key: String,
        maximum: Int
    ) throws -> String {
        guard values[key] != nil,
              let value = try optionalString(
                key,
                maximum: maximum,
                preservesBlank: true
              ) else {
            throw BibleUIAgentArgumentError(
                message: "Missing required parameter: \(key)"
            )
        }
        return value
    }

    func optionalString(
        _ key: String,
        maximum: Int = BibleUIAgentToolRequestParser.maximumIdentifierCharacters,
        preservesBlank: Bool = false
    ) throws -> String? {
        guard let raw = values[key], raw != .null else { return nil }
        guard case .string(let value) = raw else {
            throw BibleUIAgentArgumentError(message: "\(key) must be a string")
        }
        guard value.count <= maximum else {
            throw BibleUIAgentArgumentError(
                code: "LIMIT_EXCEEDED",
                message: "\(key) exceeds the maximum length"
            )
        }
        if !preservesBlank,
           value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return value
    }

    func integer(
        _ key: String,
        default defaultValue: Int,
        range: ClosedRange<Int>? = nil
    ) throws -> Int {
        guard let value = try optionalInteger(key) else { return defaultValue }
        if let range, !range.contains(value) {
            throw BibleUIAgentArgumentError(
                message: "\(key) is outside the allowed range"
            )
        }
        return value
    }

    func optionalInteger(_ key: String) throws -> Int? {
        guard let raw = values[key], raw != .null else { return nil }
        guard let value = raw.integerValue, let result = Int(exactly: value) else {
            throw BibleUIAgentArgumentError(message: "\(key) must be an integer")
        }
        return result
    }

    func optionalNonnegativeInteger(_ key: String) throws -> Int? {
        guard let value = try optionalInteger(key) else { return nil }
        guard value >= 0 else {
            throw BibleUIAgentArgumentError(message: "\(key) must not be negative")
        }
        return value
    }

    func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = values[key], raw != .null else { return defaultValue }
        guard case .bool(let value) = raw else {
            throw BibleUIAgentArgumentError(message: "\(key) must be a boolean")
        }
        return value
    }

    func requiredUUID(_ key: String) throws -> UUID {
        guard let value = try optionalUUID(key) else {
            throw BibleUIAgentArgumentError(
                message: "Missing required parameter: \(key)"
            )
        }
        return value
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let value = try optionalString(key) else { return nil }
        guard let result = UUID(uuidString: value) else {
            throw BibleUIAgentArgumentError(
                message: "\(key) must be a valid UUID"
            )
        }
        return result
    }

    func stringArray(_ key: String, default defaultValue: [String]) throws -> [String] {
        guard let raw = values[key], raw != .null else { return defaultValue }
        guard case .array(let array) = raw else {
            throw BibleUIAgentArgumentError(message: "\(key) must be an array")
        }
        guard array.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw BibleUIAgentArgumentError(
                code: "LIMIT_EXCEEDED",
                message: "\(key) exceeds the maximum count"
            )
        }
        return try array.map { value in
            guard case .string(let string) = value,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  string.count <= BibleUIAgentToolRequestParser.maximumIdentifierCharacters else {
                throw BibleUIAgentArgumentError(
                    message: "\(key) must contain bounded nonblank strings"
                )
            }
            return string
        }
    }

    func uuidArray(_ key: String, default defaultValue: [UUID]) throws -> [UUID] {
        let strings = try stringArray(key, default: [])
        if strings.isEmpty, values[key] == nil { return defaultValue }
        return try strings.map { value in
            guard let result = UUID(uuidString: value) else {
                throw BibleUIAgentArgumentError(
                    message: "\(key) must contain valid UUIDs"
                )
            }
            return result
        }
    }

    func objectArray(_ key: String) throws -> [[String: JSONValue]] {
        guard let raw = values[key], case .array(let array) = raw else {
            throw BibleUIAgentArgumentError(
                message: "Missing required parameter: \(key)"
            )
        }
        guard array.count <= BibleUIAgentToolRequestParser.maximumArrayItems else {
            throw BibleUIAgentArgumentError(
                code: "LIMIT_EXCEEDED",
                message: "\(key) exceeds the maximum count"
            )
        }
        return try array.map { value in
            guard case .object(let object) = value else {
                throw BibleUIAgentArgumentError(
                    message: "\(key) must contain objects"
                )
            }
            return object
        }
    }

    func enumeration<Value: RawRepresentable>(
        _ key: String,
        default defaultValue: Value
    ) throws -> Value where Value.RawValue == String {
        guard let raw = try optionalString(key) else { return defaultValue }
        guard let value = Value(rawValue: raw) else {
            throw BibleUIAgentArgumentError(
                message: "\(key) has an unsupported value"
            )
        }
        return value
    }

    func requiredEnumeration<Value: RawRepresentable>(
        _ key: String
    ) throws -> Value where Value.RawValue == String {
        let raw = try requiredString(key)
        guard let value = Value(rawValue: raw) else {
            throw BibleUIAgentArgumentError(
                message: "\(key) has an unsupported value"
            )
        }
        return value
    }

    func optionalEnumeration<Value: RawRepresentable>(
        _ key: String
    ) throws -> Value? where Value.RawValue == String {
        guard let raw = try optionalString(key) else { return nil }
        guard let value = Value(rawValue: raw) else {
            throw BibleUIAgentArgumentError(
                message: "\(key) has an unsupported value"
            )
        }
        return value
    }

    func enumerationSet<Value: RawRepresentable & Hashable>(
        _ key: String,
        default defaultValue: Set<Value>
    ) throws -> Set<Value> where Value.RawValue == String {
        guard values[key] != nil else { return defaultValue }
        return try Set(stringArray(key, default: []).map { raw in
            guard let value = Value(rawValue: raw) else {
                throw BibleUIAgentArgumentError(
                    message: "\(key) has an unsupported value"
                )
            }
            return value
        })
    }
}
