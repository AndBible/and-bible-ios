import Foundation
import BibleView

/**
 Wire payload for Vue's My Notes document.

 The shape matches the web client's `type: "notes"` document and keeps bookmark entries as typed
 Bible bookmark DTOs rather than pre-rendered JSON fragments.
 */
struct MyNotesDocumentPayload: Encodable {
    /// Stable document identifier for the rendered chapter notes view.
    let id: String
    /// Client document discriminator, always `notes`.
    let type: String
    /// Bible bookmarks with notes rendered in this document.
    let bookmarks: [BibleBookmarkData]
    /// Human-readable verse range covered by the notes document.
    let verseRange: String
    /// Inclusive ordinal range covered by the notes document.
    let ordinalRange: [Int]
}

/**
 Wire payload for Vue's StudyPad document.

 The payload mirrors Android's StudyPad document object while using typed bookmark, label, and
 relationship DTOs for every nested collection.
 */
struct StudyPadDocumentPayload: Encodable {
    /// Stable document identifier for the StudyPad label.
    let id: String
    /// Client document discriminator, always `journal`.
    let type: String
    /// Label whose StudyPad is being rendered.
    let label: LabelData
    /// Bible bookmarks attached to the label.
    let bookmarks: [BibleBookmarkData]
    /// Generic bookmarks attached to the label.
    let genericBookmarks: [GenericBookmarkData]
    /// Bible bookmark-to-label relationships for this label.
    let bookmarkToLabels: [BookmarkToLabelData]
    /// Generic bookmark-to-label relationships for this label.
    let genericBookmarkToLabels: [BookmarkToLabelData]
    /// StudyPad text entries attached to this label.
    let journalTextEntries: [StudyPadTextItemData]
}

/**
 Wire payload for Vue's `setup_content` event.

 All jump target keys are encoded on every emission because the web client destructures them with
 `null` defaults rather than treating omitted keys as equivalent.
 */
struct ReaderSetupContentPayload: Encodable {
    private enum CodingKeys: String, CodingKey {
        case jumpToOrdinal
        case jumpToAnchor
        case jumpToId
        case topOffset
        case bottomOffset
    }

    /// Optional ordinal to scroll to after document setup.
    let jumpToOrdinal: Int?
    /// Optional anchor id to scroll to after document setup.
    let jumpToAnchor: String?
    /// Optional element id to scroll to after document setup.
    let jumpToId: String?
    /// Top inset passed to the web client.
    let topOffset: Int
    /// Bottom inset passed to the web client.
    let bottomOffset: Int

    /**
     Creates a setup-content event payload with zero offsets by default.

     - Parameters:
       - jumpToOrdinal: Optional ordinal scroll target.
       - jumpToAnchor: Optional anchor scroll target.
       - jumpToId: Optional element-id scroll target.
       - topOffset: Top inset for the web client.
       - bottomOffset: Bottom inset for the web client.
     - Side effects: None.
     - Failure modes: None.
     */
    init(
        jumpToOrdinal: Int? = nil,
        jumpToAnchor: String? = nil,
        jumpToId: String? = nil,
        topOffset: Int = 0,
        bottomOffset: Int = 0
    ) {
        self.jumpToOrdinal = jumpToOrdinal
        self.jumpToAnchor = jumpToAnchor
        self.jumpToId = jumpToId
        self.topOffset = topOffset
        self.bottomOffset = bottomOffset
    }

    /**
     Encodes nullable jump keys explicitly for Vue's event handler.

     - Parameter encoder: Destination encoder for bridge JSON.
     - Side effects: writes all setup-content keys into the encoder.
     - Failure modes: rethrows encoder failures.
     */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let jumpToOrdinal {
            try container.encode(jumpToOrdinal, forKey: .jumpToOrdinal)
        } else {
            try container.encodeNil(forKey: .jumpToOrdinal)
        }
        if let jumpToAnchor {
            try container.encode(jumpToAnchor, forKey: .jumpToAnchor)
        } else {
            try container.encodeNil(forKey: .jumpToAnchor)
        }
        if let jumpToId {
            try container.encode(jumpToId, forKey: .jumpToId)
        } else {
            try container.encodeNil(forKey: .jumpToId)
        }
        try container.encode(topOffset, forKey: .topOffset)
        try container.encode(bottomOffset, forKey: .bottomOffset)
    }
}

/**
 Encodable representation of arbitrary JSON values already validated by `JSONSerialization`.

 This is used only for opaque Vue state blobs that native code stores and replays without
 interpreting. It lets typed bridge documents include that state without inserting a raw JSON string
 into another JSON document.
 */
enum BridgeJSONValue: Encodable {
    /// JSON null.
    case null
    /// JSON boolean.
    case bool(Bool)
    /// JSON number.
    case number(Double)
    /// JSON string.
    case string(String)
    /// JSON array.
    case array([BridgeJSONValue])
    /// JSON object.
    case object([String: BridgeJSONValue])

    /**
     Creates a typed JSON value from a `JSONSerialization` result.

     - Parameter value: Value returned from `JSONSerialization.jsonObject`.
     - Returns: A typed bridge JSON value.
     - Side effects: None.
     - Failure modes: returns `nil` when the value contains an unsupported Foundation type.
     */
    init?(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var array: [BridgeJSONValue] = []
            for item in value {
                guard let jsonValue = BridgeJSONValue(item) else { return nil }
                array.append(jsonValue)
            }
            self = .array(array)
        case let value as [String: Any]:
            var object: [String: BridgeJSONValue] = [:]
            for (key, item) in value {
                guard let jsonValue = BridgeJSONValue(item) else { return nil }
                object[key] = jsonValue
            }
            self = .object(object)
        default:
            return nil
        }
    }

    /**
     Encodes the represented JSON value into the bridge document.

     - Parameter encoder: Destination encoder for bridge JSON.
     - Side effects: writes this value into the encoder.
     - Failure modes: rethrows encoder failures.
     */
    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in values.keys.sorted() {
                guard let codingKey = DynamicCodingKey(stringValue: key),
                      let value = values[key] else { continue }
                try container.encode(value, forKey: codingKey)
            }
        }
    }
}

/**
 Dynamic coding key used for opaque JSON object state.
 */
private struct DynamicCodingKey: CodingKey {
    /// String key carried by an arbitrary JSON object.
    let stringValue: String
    /// Integer keys are unsupported for JSON objects.
    let intValue: Int? = nil

    /**
     Creates a string coding key.

     - Parameter stringValue: JSON object key name.
     - Side effects: None.
     - Failure modes: None.
     */
    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    /**
     Rejects integer keys because JSON object state uses string keys.

     - Parameter intValue: Unsupported integer coding key.
     - Failure modes: Always returns `nil`.
     */
    init?(intValue: Int) {
        return nil
    }
}

/**
 Wire payload for Vue's multi-fragment document.

 `state` and `contentType` are omitted when absent, matching the previous document shape while
 using typed `OsisFragment` values for all rendered fragments.
 */
struct MultiFragmentDocumentPayload: Encodable {
    /// Stable document identifier.
    let id: String
    /// Client document discriminator, always `multi`.
    let type: String
    /// Rendered OSIS fragments in display order.
    let osisFragments: [OsisFragment]
    /// Whether this is a Bible comparison document.
    let compare: Bool
    /// Optional content type such as `strongs`.
    let contentType: String?
    /// Optional opaque Vue state restored into the document.
    let state: BridgeJSONValue?
}

/**
 Wire payload for Vue's StudyPad update event.

 The web client expects all four keys on every `add_or_update_study_pad` event, with
 `studyPadTextEntry` explicitly set to `null` for reorder-only updates.
 */
struct StudyPadUpdatePayload: Encodable {
    private enum CodingKeys: String, CodingKey {
        case studyPadTextEntry
        case bookmarkToLabelsOrdered
        case genericBookmarkToLabelsOrdered
        case studyPadItemsOrdered
    }

    /// Newly created or changed StudyPad text entry, or `nil` for reorder-only updates.
    let studyPadTextEntry: StudyPadTextItemData?
    /// Changed Bible bookmark-to-label relationships in StudyPad order.
    let bookmarkToLabelsOrdered: [BookmarkToLabelData]
    /// Changed generic bookmark-to-label relationships in StudyPad order.
    let genericBookmarkToLabelsOrdered: [BookmarkToLabelData]
    /// Changed StudyPad text entries in StudyPad order.
    let studyPadItemsOrdered: [StudyPadTextItemData]

    /**
     Encodes all StudyPad event keys, preserving explicit `null` for absent entries.

     - Parameter encoder: Destination encoder for bridge JSON.
     - Side effects: writes this event payload into the encoder.
     - Failure modes: rethrows encoder failures.
     */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let studyPadTextEntry {
            try container.encode(studyPadTextEntry, forKey: .studyPadTextEntry)
        } else {
            try container.encodeNil(forKey: .studyPadTextEntry)
        }
        try container.encode(bookmarkToLabelsOrdered, forKey: .bookmarkToLabelsOrdered)
        try container.encode(genericBookmarkToLabelsOrdered, forKey: .genericBookmarkToLabelsOrdered)
        try container.encode(studyPadItemsOrdered, forKey: .studyPadItemsOrdered)
    }
}
