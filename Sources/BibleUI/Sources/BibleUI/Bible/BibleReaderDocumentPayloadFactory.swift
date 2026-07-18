// BibleReaderDocumentPayloadFactory.swift - Vue document payload assembly for reader content

import Foundation
import BibleCore
import BibleView
import os.log

private let documentPayloadLogger = Logger(subsystem: "org.andbible", category: "BibleReaderDocumentPayloadFactory")

/**
 Describes one OSIS-backed document payload the native reader sends to the Vue document renderer.

 `BibleReaderController` decides what content should be shown. This value carries only the stable
 bridge contract fields needed to serialize that content, so document JSON assembly can be tested
 and evolved without coupling it to controller navigation, modal, or persistence responsibilities.

 - Side effects: None; this is an immutable request value.
 - Failure modes: None during initialization. Invalid combinations are handled by the factory when
   it cannot resolve a required Bible ordinal range or cannot serialize the resulting JSON object.
 */
struct BibleReaderDocumentPayloadRequest {
    /// OSIS book or pseudo-book identifier emitted as `bookAbbreviation`.
    let osisBookId: String
    /// User-visible book/document name emitted in document metadata.
    let bookName: String
    /// One-based chapter number for Bible-like documents and placeholder chapter metadata.
    let chapter: Int
    /// Number of verses represented by the OSIS fragment.
    let verseCount: Int
    /// Whether the fragment belongs to a New Testament document.
    let isNewTestament: Bool
    /// OSIS or OSIS-like XML consumed by the web renderer.
    let xml: String
    /// Bible bookmarks associated with the represented range.
    let bookmarks: [BibleBookmark]
    /// Raw `DocumentCategory` bridge value such as `BIBLE`, `COMMENTARY`, or `DICTIONARY`.
    let bookCategory: String
    /// Optional module initials override. `nil` uses the active Bible module initials.
    let bookInitials: String?
    /// Whether Vue should inject a chapter marker for this document.
    let addChapter: Bool
    /// Optional original navigation target used by highlight restoration.
    let originalOrdinalRange: [Int]?
    /// Optional exact document key. Bible chapters default to `Book.Chapter`.
    let documentKey: String?
    /// Optional display label for the document key.
    let keyName: String?
    /// Optional exact ordinal range for single-key or non-chapter documents.
    let ordinalRangeOverride: [Int]?

    /**
     Creates a document payload request while preserving the controller's historical defaults.

     - Parameters mirror the legacy `BibleReaderController.buildDocumentJSON(...)` signature so
       callers can migrate incrementally without changing emitted document semantics.
     - Side effects: None.
     - Failure modes: None; validation is deferred until serialization.
     */
    init(
        osisBookId: String,
        bookName: String,
        chapter: Int,
        verseCount: Int,
        isNewTestament: Bool,
        xml: String,
        bookmarks: [BibleBookmark] = [],
        bookCategory: String = DocumentCategory.bible.rawValue,
        bookInitials: String? = nil,
        addChapter: Bool = true,
        originalOrdinalRange: [Int]? = nil,
        documentKey: String? = nil,
        keyName: String? = nil,
        ordinalRangeOverride: [Int]? = nil
    ) {
        self.osisBookId = osisBookId
        self.bookName = bookName
        self.chapter = chapter
        self.verseCount = verseCount
        self.isNewTestament = isNewTestament
        self.xml = xml
        self.bookmarks = bookmarks
        self.bookCategory = bookCategory
        self.bookInitials = bookInitials
        self.addChapter = addChapter
        self.originalOrdinalRange = originalOrdinalRange
        self.documentKey = documentKey
        self.keyName = keyName
        self.ordinalRangeOverride = ordinalRangeOverride
    }
}

/**
 Builds the JSON document records emitted to the Vue reader.

 The factory owns the bridge payload schema for rendered documents. Controller-owned concerns are
 supplied as closures: module initials, JSword/SWORD ordinal lookup, bookmark projection, reading
 progress, and memorization progress. This keeps JSON shape centralized without letting the factory
 mutate reader state or know about windows, modals, or bridge event routing.

 Side effects:
 - calls supplied closures to project bookmarks and read progress snapshots
 - logs serialization failures

 Failure modes:
 - returns `nil` for Bible documents whose ordinal range cannot be resolved
 - returns `nil` when JSON serialization fails
 - omits bookmark payloads that fail the shared bridge encoder, matching the prior controller logic
 */
struct BibleReaderDocumentPayloadFactory {
    /**
     Severity values understood by Vue's `ErrorDocument` renderer.

     Android distinguishes ordinary no-content states from reportable reader errors. Keeping that
     distinction in the bridge payload lets native code render "No content for selected verse"
     without showing the report-error affordance used for unexpected failures.

     Side effects: none.
     Failure modes: none.
     */
    enum ErrorDocumentSeverity: String {
        /// User-visible informational state such as a valid key with no renderable content.
        case normal = "NORMAL"

        /// Recoverable warning state that should not be treated as a crash/reportable error.
        case warning = "WARNING"

        /// Unexpected reader error that Vue should render with the report-error action.
        case error = "ERROR"
    }

    /**
     Resolves the ordinal range for a Bible chapter.

     - Parameters are display book name, one-based chapter, and caller-supplied verse count.
     - Returns the start/end ordinals plus resolved verse count, or `nil` when the active module
       cannot resolve the chapter.
     */
    typealias ChapterOrdinalRangeResolver = (String, Int, Int) -> (start: Int, end: Int, verseCount: Int)?

    /// Projects one persisted Bible bookmark into the typed Vue bridge DTO.
    typealias BookmarkPayloadBuilder = (BibleBookmark) -> BibleBookmarkData

    /// Maps a display book name to the KJV book ordinal used by reading-progress persistence.
    typealias KJVBookOrdinalResolver = (String) -> Int?

    /// Reads the chapter read count for a KJV book ordinal/chapter pair.
    typealias ChapterReadCountProvider = (Int, Int) -> Int?

    /// Reads memorization ordinals for the supplied module initials and rendered ordinal range.
    typealias OrdinalProgressProvider = (String, Int, Int) -> [Int]

    /// Active Bible module initials used when a request does not override `bookInitials`.
    private let activeModuleName: String
    /// Whether the active Bible document exposes Strong's metadata.
    private let hasStrongs: Bool
    /// Controller-supplied bookmark payload projection.
    private let bookmarkPayload: BookmarkPayloadBuilder
    /// Controller/SWORD-supplied Bible ordinal lookup.
    private let chapterOrdinalRange: ChapterOrdinalRangeResolver
    /// Controller-supplied KJV ordinal lookup for reading progress.
    private let kjvBookOrdinal: KJVBookOrdinalResolver
    /// Reading-progress store snapshot access.
    private let chapterReadCount: ChapterReadCountProvider
    /// Memorized ordinal lookup.
    private let memorizedOrdinals: OrdinalProgressProvider
    /// Memorization target ordinal lookup.
    private let targetOrdinals: OrdinalProgressProvider

    /**
     Creates a document payload factory for one snapshot of controller reader state.

     - Parameters:
       - activeModuleName: Module initials used by default for `bookInitials`.
       - hasStrongs: Whether Bible fragments should advertise Strong's support.
       - bookmarkPayload: Converts `BibleBookmark` models to bridge DTOs.
       - chapterOrdinalRange: Resolves Bible chapter ordinal ranges through active versification.
       - kjvBookOrdinal: Resolves KJV book ordinals for reading progress.
       - chapterReadCount: Reads persisted read counts for rendered Bible chapters.
       - memorizedOrdinals: Reads memorized ordinals for the rendered range.
       - targetOrdinals: Reads memorization target ordinals for the rendered range.
     - Side effects: None during initialization; closures are invoked by serialization methods.
     - Failure modes: None during initialization.
     */
    init(
        activeModuleName: String,
        hasStrongs: Bool,
        bookmarkPayload: @escaping BookmarkPayloadBuilder,
        chapterOrdinalRange: @escaping ChapterOrdinalRangeResolver,
        kjvBookOrdinal: @escaping KJVBookOrdinalResolver,
        chapterReadCount: @escaping ChapterReadCountProvider,
        memorizedOrdinals: @escaping OrdinalProgressProvider,
        targetOrdinals: @escaping OrdinalProgressProvider
    ) {
        self.activeModuleName = activeModuleName
        self.hasStrongs = hasStrongs
        self.bookmarkPayload = bookmarkPayload
        self.chapterOrdinalRange = chapterOrdinalRange
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapterReadCount = chapterReadCount
        self.memorizedOrdinals = memorizedOrdinals
        self.targetOrdinals = targetOrdinals
    }

    /**
     Serializes an OSIS-backed reader document in the shape expected by Vue.

     - Parameter request: Complete payload description for the document being rendered.
     - Returns: JSON for one Vue document record, or `nil` when required Bible range data or JSON
       serialization is unavailable.
     - Side effects: Reads bookmark/progress data through injected closures and logs failures.
     - Failure modes: Bible documents require a resolvable ordinal range unless an override is
       supplied; non-Bible documents default to `[0, 0]` to preserve existing bridge semantics.
     */
    func documentJSON(_ request: BibleReaderDocumentPayloadRequest) -> String? {
        let key = request.documentKey ?? "\(request.osisBookId).\(request.chapter)"
        let displayKeyName = request.keyName ?? "\(request.bookName) \(request.chapter)"
        let documentOrdinalRange: [Int]
        if let ordinalRangeOverride = request.ordinalRangeOverride {
            documentOrdinalRange = ordinalRangeOverride
        } else if request.bookCategory == DocumentCategory.bible.rawValue {
            guard let range = chapterOrdinalRange(request.bookName, request.chapter, request.verseCount) else {
                documentPayloadLogger.error(
                    "Failed to resolve Bible document range for \(request.osisBookId, privacy: .public).\(request.chapter)"
                )
                return nil
            }
            documentOrdinalRange = [range.start, range.end]
        } else {
            documentOrdinalRange = [0, 0]
        }

        let ordinalStart = documentOrdinalRange.first ?? 0
        let ordinalEnd = documentOrdinalRange.last ?? ordinalStart
        let initials = request.bookInitials ?? activeModuleName
        let bookmarkObjects = request.bookmarks.compactMap { jsonObject(from: bookmarkPayload($0)) }
        let chapterReadCountValue = chapterReadCountValue(
            bookCategory: request.bookCategory,
            bookName: request.bookName,
            chapter: request.chapter
        )

        var doc: [String: Any] = [
            "id": "doc-1",
            "type": "bible",
            "osisFragment": osisFragmentObject(
                request: request,
                key: key,
                displayKeyName: displayKeyName,
                initials: initials,
                ordinalRange: documentOrdinalRange
            ),
            "bookInitials": initials,
            "bookCategory": request.bookCategory,
            "bookAbbreviation": request.osisBookId,
            "bookName": request.bookName,
            "key": key,
            "v11n": "KJVA",
            "osisRef": key,
            "annotateRef": "",
            "genericBookmarks": [Any](),
            "ordinalRange": documentOrdinalRange,
            "isNativeHtml": false,
            "bookmarks": bookmarkObjects,
            "bibleBookName": request.bookName,
            "addChapter": request.addChapter,
            "chapterNumber": request.chapter,
            "originalOrdinalRange": request.originalOrdinalRange ?? NSNull(),
            "memorizedOrdinals": memorizedOrdinals(initials, ordinalStart, ordinalEnd),
            "targetOrdinals": targetOrdinals(initials, ordinalStart, ordinalEnd),
        ]
        if let chapterReadCountValue {
            doc["chapterReadCount"] = chapterReadCountValue
        }

        return serializedDocument(doc, failureDescription: "\(request.osisBookId) \(request.chapter)")
    }

    /**
     Serializes EPUB XHTML as a native-HTML OSIS document for the Vue reader.

     Android routes EPUB-like general content through the same document surface as other reader
     documents. iOS must mark this payload as `isNativeHtml` and use document type `osis` so the
     Vue `OsisDocument` path passes the HTML through to `OsisFragment` without OSIS conversion.

     - Parameters:
       - bookName: Visible EPUB section title.
       - bookInitials: Parent EPUB title used as document initials.
       - content: Rewritten XHTML/HTML content loaded from the EPUB index.
     - Returns: Serialized JSON payload. Returns `{}` if JSON serialization fails.
     - Side effects: Logs serialization failures.
     - Failure modes: Invalid JSON object construction returns `{}` to match the previous
       controller behavior.
     */
    func epubDocumentJSON(bookName: String, bookInitials: String, content: String) -> String {
        let doc: [String: Any] = [
            "id": "doc-1",
            "type": "osis",
            "osisFragment": [
                "xml": content,
                "key": "epub",
                "keyName": bookName,
                "v11n": "KJVA",
                "bookCategory": DocumentCategory.generalBook.rawValue,
                "bookInitials": bookInitials,
                "bookAbbreviation": "Epub",
                "osisRef": "epub",
                "isNewTestament": false,
                "features": [String: Any](),
                "hasStrongs": false,
                "ordinalRange": [0, 0],
                "language": "en",
                "direction": "ltr"
            ] as [String: Any],
            "bookInitials": bookInitials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": "Epub",
            "bookName": bookName,
            "key": "epub",
            "v11n": "KJVA",
            "osisRef": "epub",
            "annotateRef": "",
            "genericBookmarks": [Any](),
            "ordinalRange": [0, 0],
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull()
        ]

        return serializedDocument(doc, failureDescription: "EPUB document") ?? "{}"
    }

    /**
     Serializes a Vue `ErrorDocument` payload for reader-visible content failures.

     Android surfaces empty-content reader states as document errors instead of leaving the reader
     loading. iOS uses the same Vue error-document type so native SWORD failures that happen after a
     module is already installed can stop the spinner while remaining distinct from download/install
     failures.

     - Parameters:
       - message: User-visible message rendered by `ErrorDocument` through the OSIS segment path.
       - severity: Error-document severity controlling the title and report-error affordance.
     - Returns: Serialized JSON payload, or `nil` when JSON serialization fails.
     - Side effects: Logs serialization failures through `serializedDocument`.
     - Failure modes: Returns `nil` if the document dictionary cannot be serialized.
     */
    func errorDocumentJSON(
        message: String,
        severity: ErrorDocumentSeverity = .normal
    ) -> String? {
        let doc: [String: Any] = [
            "id": "doc-1",
            "type": "error",
            "errorMessage": message,
            "severity": severity.rawValue
        ]

        return serializedDocument(doc, failureDescription: "reader error document")
    }

    /**
     Builds the nested OSIS fragment object shared by Bible and OSIS-like auxiliary documents.

     - Parameters:
       - request: Source document metadata and XML content.
       - key: Exact Vue document key and OSIS reference.
       - displayKeyName: Human-readable key label shown by the web reader.
       - initials: Module initials already resolved from the request or active Bible module.
       - ordinalRange: Ordinal range emitted at both document and fragment levels.
     - Returns: A JSON-compatible dictionary for the document's `osisFragment` field.
     - Side effects: None.
     - Failure modes: None directly; JSON compatibility is validated by `serializedDocument`.
     */
    private func osisFragmentObject(
        request: BibleReaderDocumentPayloadRequest,
        key: String,
        displayKeyName: String,
        initials: String,
        ordinalRange: [Int]
    ) -> [String: Any] {
        [
            "xml": request.xml,
            "key": key,
            "keyName": displayKeyName,
            "v11n": "KJVA",
            "bookCategory": request.bookCategory,
            "bookInitials": initials,
            "bookAbbreviation": request.osisBookId,
            "osisRef": key,
            "isNewTestament": request.isNewTestament,
            "features": [String: Any](),
            "hasStrongs": hasStrongs,
            "ordinalRange": ordinalRange,
            "language": "en",
            "direction": "ltr",
        ]
    }

    /**
     Resolves optional reading-progress metadata for Bible documents only.

     - Parameters:
       - bookCategory: Raw document category value supplied by the request.
       - bookName: Display book name used to resolve a KJV book ordinal.
       - chapter: One-based chapter number.
     - Returns: Stored chapter read count when the document is a Bible chapter and the KJV ordinal
       can be resolved; otherwise `nil` so non-Bible documents omit the field.
     - Side effects: Reads through the injected progress closures only.
     - Failure modes: Missing KJV ordinal or progress data is represented as `nil`.
     */
    private func chapterReadCountValue(bookCategory: String, bookName: String, chapter: Int) -> Int? {
        guard bookCategory == DocumentCategory.bible.rawValue,
              let ordinal = kjvBookOrdinal(bookName) else {
            return nil
        }
        return chapterReadCount(ordinal, chapter)
    }

    /**
     Converts a typed bridge DTO into a JSON-compatible object for inclusion in document payloads.

     - Parameter value: Encodable bridge value using the shared `bridgeEncoder`.
     - Returns: Foundation JSON object on success, or `nil` when encoding/parsing fails.
     - Side effects: None.
     - Failure modes: Encoding failures are intentionally dropped to preserve the prior compact-map
       behavior for bookmark payloads.
     */
    private func jsonObject<T: Encodable>(from value: T) -> Any? {
        guard let data = try? bridgeEncoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /**
     Serializes one assembled document dictionary for bridge emission.

     - Parameters:
       - doc: JSON-compatible document dictionary.
       - failureDescription: Log context identifying the document being serialized.
     - Returns: UTF-8 JSON string sorted by key for deterministic tests, or `nil` on failure.
     - Side effects: Logs serialization failures.
     - Failure modes: Non-JSON values or UTF-8 conversion failure prevent document emission.
     */
    private func serializedDocument(_ doc: [String: Any], failureDescription: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            documentPayloadLogger.error("Failed to serialize document JSON for \(failureDescription, privacy: .public)")
            return nil
        }
        return json
    }
}
