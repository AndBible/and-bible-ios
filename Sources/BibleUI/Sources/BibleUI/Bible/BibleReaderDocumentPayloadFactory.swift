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
    /// Optional source-versification range for the nested OSIS fragment.
    let fragmentOrdinalRange: [Int]?
    /// Optional exact fragment identity when it differs from `initials--documentKey`.
    let fragmentKey: String?
    /// Optional exact fragment OSIS reference when it differs from the document key.
    let fragmentOsisRef: String?
    /// Optional annotation reference declared by source OSIS.
    let annotateRef: String?
    /// Source-derived fragment features exposed to Vue.
    let fragmentFeatures: [String: String]
    /// Android commentary block metadata, or `nil` for non-commentary content and empty blocks.
    let commentaryRange: ReaderCommentaryRangePayload?
    /// Source module display name exposed as Android's document `bookName`.
    let moduleName: String?
    /// Source module abbreviation exposed at document and fragment levels.
    let moduleAbbreviation: String?
    /// Exact source-module versification, or `nil` for a document without a verse domain.
    let versificationName: String?
    /// Source module language code.
    let language: String
    /// Source module reading direction.
    let direction: String
    /// Optional source-specific Strong's capability override.
    let sourceHasStrongs: Bool?
    /// Authoritative KJVA range used for Android's Bible AI-marker overlap query.
    let aiMarkerKJVAOrdinalRange: [Int]?

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
        ordinalRangeOverride: [Int]? = nil,
        fragmentOrdinalRange: [Int]? = nil,
        fragmentKey: String? = nil,
        fragmentOsisRef: String? = nil,
        annotateRef: String? = nil,
        fragmentFeatures: [String: String] = [:],
        commentaryRange: ReaderCommentaryRangePayload? = nil,
        moduleName: String? = nil,
        moduleAbbreviation: String? = nil,
        versificationName: String? = nil,
        language: String = "en",
        direction: String = "ltr",
        sourceHasStrongs: Bool? = nil,
        aiMarkerKJVAOrdinalRange: [Int]? = nil
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
        self.fragmentOrdinalRange = fragmentOrdinalRange
        self.fragmentKey = fragmentKey
        self.fragmentOsisRef = fragmentOsisRef
        self.annotateRef = annotateRef
        self.fragmentFeatures = fragmentFeatures
        self.commentaryRange = commentaryRange
        self.moduleName = moduleName
        self.moduleAbbreviation = moduleAbbreviation
        self.versificationName = versificationName
        self.language = language
        self.direction = direction
        self.sourceHasStrongs = sourceHasStrongs
        self.aiMarkerKJVAOrdinalRange = aiMarkerKJVAOrdinalRange
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
    /// Exact generic bookmark projection for one source document and key.
    private let genericBookmarks: (String, String) -> [GenericBookmarkData]
    /// Exact generated-page marker projection for one non-Bible source document and key.
    private let aiDocMarkersForPage: (String, String) -> [MyDocumentAIDocMarker]
    /// Generated-page marker projection for one authoritative Bible KJVA range.
    private let aiDocMarkersForKJVARange: (Int, Int) -> [MyDocumentAIDocMarker]

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
       - genericBookmarks: Projects persisted generic annotations for exact source identities.
       - aiDocMarkersForPage: Projects generated-page markers for exact non-Bible source identities.
       - aiDocMarkersForKJVARange: Projects markers overlapping an authoritative Bible KJVA range.
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
        targetOrdinals: @escaping OrdinalProgressProvider,
        genericBookmarks: @escaping (String, String) -> [GenericBookmarkData] = { _, _ in [] },
        aiDocMarkersForPage: @escaping (String, String) -> [MyDocumentAIDocMarker] = { _, _ in [] },
        aiDocMarkersForKJVARange: @escaping (Int, Int) -> [MyDocumentAIDocMarker] = { _, _ in [] }
    ) {
        self.activeModuleName = activeModuleName
        self.hasStrongs = hasStrongs
        self.bookmarkPayload = bookmarkPayload
        self.chapterOrdinalRange = chapterOrdinalRange
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapterReadCount = chapterReadCount
        self.memorizedOrdinals = memorizedOrdinals
        self.targetOrdinals = targetOrdinals
        self.genericBookmarks = genericBookmarks
        self.aiDocMarkersForPage = aiDocMarkersForPage
        self.aiDocMarkersForKJVARange = aiDocMarkersForKJVARange
    }

    /**
     Serializes an OSIS-backed reader document in the shape expected by Vue.

     - Parameter request: Complete payload description for the document being rendered.
     - Returns: JSON for one Vue document record, or `nil` when required Bible range data or JSON
       serialization is unavailable.
     - Side effects: Reads bookmark/progress data through injected closures and logs failures.
     - Failure modes: Bible documents require both a source versification and a resolvable ordinal
       range unless an override is supplied. Non-verse-key documents preserve null range metadata.
     */
    func documentJSON(_ request: BibleReaderDocumentPayloadRequest) -> String? {
        let key = request.documentKey ?? "\(request.osisBookId).\(request.chapter)"
        let displayKeyName = request.keyName ?? "\(request.bookName) \(request.chapter)"
        let isBibleDocument = request.bookCategory == DocumentCategory.bible.rawValue
        let documentOrdinalRange: [Int]?
        if let ordinalRangeOverride = request.ordinalRangeOverride {
            documentOrdinalRange = ordinalRangeOverride
        } else if isBibleDocument {
            guard let range = chapterOrdinalRange(request.bookName, request.chapter, request.verseCount) else {
                documentPayloadLogger.error(
                    "Failed to resolve Bible document range for \(request.osisBookId, privacy: .public).\(request.chapter)"
                )
                return nil
            }
            documentOrdinalRange = [range.start, range.end]
        } else {
            documentOrdinalRange = nil
        }

        guard !isBibleDocument || request.versificationName != nil else {
            documentPayloadLogger.error(
                "Refusing Bible payload without a source versification for \(request.osisBookId, privacy: .public).\(request.chapter)"
            )
            return nil
        }

        let ordinalStart = documentOrdinalRange?.first ?? 0
        let ordinalEnd = documentOrdinalRange?.last ?? ordinalStart
        let initials = request.bookInitials ?? activeModuleName
        let abbreviation = request.moduleAbbreviation ?? initials
        let moduleDisplayName = request.moduleName ?? initials
        let annotateRef = request.annotateRef ?? key
        let documentOsisRef = request.annotateRef ?? request.fragmentOsisRef ?? key
        let bookmarkObjects = request.bookmarks.compactMap { jsonObject(from: bookmarkPayload($0)) }
        let genericBookmarkObjects = isBibleDocument
            ? []
            : genericBookmarks(initials, annotateRef).compactMap { jsonObject(from: $0) }
        let markers: [MyDocumentAIDocMarker]
        if isBibleDocument,
           let range = request.aiMarkerKJVAOrdinalRange,
           let start = range.first,
           let end = range.last {
            markers = aiDocMarkersForKJVARange(min(start, end), max(start, end))
        } else if isBibleDocument {
            markers = []
        } else {
            markers = aiDocMarkersForPage(initials, annotateRef)
        }
        let markerObjects = markers.map {
            BibleReaderMyDocumentCoordinator.markerJSON(
                $0,
                targetVersification: isBibleDocument ? request.versificationName : nil
            )
        }
        let chapterReadCountValue = chapterReadCountValue(
            bookCategory: request.bookCategory,
            bookName: request.bookName,
            chapter: request.chapter
        )

        var doc: [String: Any] = [
            "id": Self.androidDocumentID(bookInitials: initials, key: key),
            "type": isBibleDocument ? "bible" : "osis",
            "osisFragment": osisFragmentObject(
                request: request,
                key: key,
                displayKeyName: displayKeyName,
                initials: initials,
                ordinalRange: request.fragmentOrdinalRange
                    ?? (isBibleDocument ? documentOrdinalRange : nil)
            ),
            "bookInitials": initials,
            "bookCategory": request.bookCategory,
            "bookAbbreviation": abbreviation,
            "bookName": moduleDisplayName,
            "key": key,
            "v11n": request.versificationName ?? NSNull(),
            "osisRef": documentOsisRef,
            "annotateRef": annotateRef,
            "genericBookmarks": genericBookmarkObjects,
            "ordinalRange": documentOrdinalRange ?? NSNull(),
            "isNativeHtml": false,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": false,
            "isAiDocument": false,
            "myDocumentPageId": NSNull(),
            "sourcePromptId": NSNull(),
            "sourcePromptName": NSNull(),
            "sourceModelName": NSNull(),
            "aiDocMarkers": markerObjects,
            "commentaryRange": request.commentaryRange
                .flatMap { jsonObject(from: $0) } ?? NSNull(),
        ]
        if isBibleDocument {
            doc["bookmarks"] = bookmarkObjects
            doc["bibleBookName"] = request.bookName
            doc["addChapter"] = request.addChapter
            doc["chapterNumber"] = request.chapter
            doc["originalOrdinalRange"] = request.originalOrdinalRange ?? NSNull()
            doc["memorizedOrdinals"] = memorizedOrdinals(initials, ordinalStart, ordinalEnd)
            doc["targetOrdinals"] = targetOrdinals(initials, ordinalStart, ordinalEnd)
            if let chapterReadCountValue {
                doc["chapterReadCount"] = chapterReadCountValue
            }
        }

        return serializedDocument(doc, failureDescription: "\(request.osisBookId) \(request.chapter)")
    }

    /**
     Serializes EPUB XHTML as a native-HTML OSIS document for the Vue reader.

     Android routes EPUB-like general content through the same document surface as other reader
     documents. iOS must mark this payload as `isNativeHtml` and use document type `osis` so the
     Vue `OsisDocument` path passes the HTML through to `OsisFragment` without OSIS conversion.

     - Parameters:
       - bookName: EPUB package title exposed as Android's general-book name.
       - bookInitials: Stable Android-compatible EPUB document initials.
       - key: Numeric general-book fragment key.
       - keyName: Visible EPUB section or TOC-entry title.
       - content: Rewritten XHTML/HTML content loaded from the EPUB index.
       - ordinalRange: Inclusive BVA range inside the source spine document.
       - language: EPUB package language used by the renderer.
       - genericBookmarks: Generic annotations projected for this exact document/key.
     - Returns: Serialized JSON payload. Returns `{}` if JSON serialization fails.
     - Side effects: Logs serialization failures.
     - Failure modes: Invalid JSON object construction returns `{}` to match the previous
       controller behavior.
     */
    func epubDocumentJSON(
        bookName: String,
        bookInitials: String,
        key: String,
        keyName: String,
        content: String,
        ordinalRange: [Int],
        language: String,
        genericBookmarks: [GenericBookmarkData] = []
    ) -> String {
        let direction = Self.isRightToLeft(language: language) ? "rtl" : "ltr"
        let fragmentKey = "\(bookInitials)--\(key)"
        let hydratedBookmarks = self.genericBookmarks(bookInitials, key)
        let markers = aiDocMarkersForPage(bookInitials, key)
        let doc: [String: Any] = [
            "id": Self.androidDocumentID(bookInitials: bookInitials, key: key),
            "type": "osis",
            "osisFragment": [
                "xml": content,
                "key": fragmentKey,
                "keyName": keyName,
                "v11n": NSNull(),
                "bookCategory": DocumentCategory.generalBook.rawValue,
                "bookInitials": bookInitials,
                "bookAbbreviation": bookName,
                "osisRef": key,
                "isNewTestament": false,
                "features": [String: Any](),
                "hasStrongs": false,
                "ordinalRange": ordinalRange,
                "language": language,
                "direction": direction
            ] as [String: Any],
            "bookInitials": bookInitials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": bookName,
            "bookName": bookName,
            "key": key,
            "v11n": NSNull(),
            "osisRef": key,
            "annotateRef": key,
            "genericBookmarks": (genericBookmarks.isEmpty ? hydratedBookmarks : genericBookmarks)
                .compactMap { jsonObject(from: $0) },
            "ordinalRange": ordinalRange,
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull(),
            "aiDocMarkers": markers.map { BibleReaderMyDocumentCoordinator.markerJSON($0) },
        ]

        return serializedDocument(doc, failureDescription: "EPUB document") ?? "{}"
    }

    /**
     Builds Android's DOM-safe document identifier for one EPUB general-book key.

     Android replaces every scalar outside Unicode letters and ASCII digits in
     `<book initials>-<key>` with `_`. The identifier is presentation-only; portable EPUB
     identity remains the unsanitized `bookInitials` and numeric `key` fields.

     - Parameters:
       - bookInitials: Exact Android-compatible EPUB initials, including retained `A-z` punctuation.
       - key: Numeric EPUB fragment key.
     - Returns: A deterministic DOM-safe document identifier.
     - Side effects: None.
     - Failure modes: None; every input scalar maps to itself or `_`.
     */
    private static func androidDocumentID(bookInitials: String, key: String) -> String {
        "\(bookInitials)-\(key)".unicodeScalars.map { scalar in
            if CharacterSet.letters.contains(scalar) || (48...57).contains(scalar.value) {
                return String(scalar)
            }
            return "_"
        }.joined()
    }

    /// Returns whether a package language normally renders right-to-left.
    private static func isRightToLeft(language: String) -> Bool {
        let primary = language.split(separator: "-").first?.lowercased() ?? ""
        return ["ar", "fa", "he", "iw", "ps", "ur", "yi"].contains(primary)
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
       - ordinalRange: Source-versification range for a Bible fragment. Generic/commentary
         documents pass `nil` because their top-level local `BVA` range is not a verse-key range.
     - Returns: A JSON-compatible dictionary for the document's `osisFragment` field.
     - Side effects: None.
     - Failure modes: None directly; JSON compatibility is validated by `serializedDocument`.
     */
    private func osisFragmentObject(
        request: BibleReaderDocumentPayloadRequest,
        key: String,
        displayKeyName: String,
        initials: String,
        ordinalRange: [Int]?
    ) -> [String: Any] {
        [
            "xml": request.xml,
            "key": request.fragmentKey ?? "\(initials)--\(key)",
            "keyName": displayKeyName,
            "v11n": request.versificationName ?? NSNull(),
            "bookCategory": request.bookCategory,
            "bookInitials": initials,
            "bookAbbreviation": request.moduleAbbreviation ?? initials,
            "osisRef": request.fragmentOsisRef ?? key,
            "isNewTestament": request.isNewTestament,
            "features": request.fragmentFeatures,
            "hasStrongs": request.sourceHasStrongs ?? (initials == activeModuleName && hasStrongs),
            "ordinalRange": ordinalRange ?? NSNull(),
            "language": request.language,
            "direction": request.direction,
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
