// BibleReaderPreparedDocumentPayload.swift -- Immutable off-main Vue document encoding

import BibleCore
import BibleView
import Foundation
import SwordKit
import os.log

private let preparedDocumentLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderPreparedDocumentPayload"
)

/** Copied source presentation and verse-domain metadata attached to a prepared document. */
struct BibleReaderPreparedSourceMetadata: Sendable {
    let initials: String
    let name: String
    let abbreviation: String
    let versificationName: String
    let language: String
    let direction: String
    let hasStrongs: Bool
}

/** Source-owned chapter ranges copied before persistence annotations are queried. */
struct BibleReaderPreparedBibleChapterStructure: Sendable {
    let sourceOrdinalStart: Int
    let sourceOrdinalEnd: Int
    let sourceVerseCount: Int
    let bookmarkKJVAOrdinalStart: Int
    let bookmarkKJVAOrdinalEnd: Int
    let markerKJVAOrdinalStart: Int
    let markerKJVAOrdinalEnd: Int
    let readingProgressKJVABookOrdinal: Int?
    let sourceVersification: String
    let ordinalByVerse: [Int: Int]
    let memorizationProjections: [
        BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection
    ]
}

/** Exact bridge-visible identity for one copied AI document marker. */
private struct BibleReaderAIDocMarkerIdentity: Hashable, Sendable {
    let pageID: UUID
    let documentID: UUID
    let documentInitials: BibleReaderPreparationExactText
    let pageTitle: BibleReaderPreparationExactText
    let pageKey: BibleReaderPreparationExactText
    let kjvOrdinalStart: Int?
    let kjvOrdinalEnd: Int?
    let sourcePromptID: UUID?
    let sourceBookInitials: BibleReaderPreparationExactText?
    let sourceBookKey: BibleReaderPreparationExactText?

    init(_ value: MyDocumentAIDocMarker) {
        pageID = value.pageId
        documentID = value.documentId
        documentInitials = BibleReaderPreparationExactText(value.documentInitials)
        pageTitle = BibleReaderPreparationExactText(value.pageTitle)
        pageKey = BibleReaderPreparationExactText(value.pageKey)
        kjvOrdinalStart = value.kjvOrdinalStart
        kjvOrdinalEnd = value.kjvOrdinalEnd
        sourcePromptID = value.sourcePromptId
        sourceBookInitials = value.sourceBookInitials.map { BibleReaderPreparationExactText($0) }
        sourceBookKey = value.sourceBookKey.map { BibleReaderPreparationExactText($0) }
    }
}

/**
 Exact owner-side identity for every non-source value in one prepared Bible document.

 The identity is Hashable for exact in-flight coalescing and Equatable for one final owner
 validation. It contains copied bridge values rather than SwiftData models or raw chapter XML.
 */
struct BibleReaderBibleDocumentOwnerIdentity: Hashable, Sendable {
    let osisBookID: BibleReaderPreparationExactText
    let bookName: BibleReaderPreparationExactText
    let chapter: Int
    let isNewTestament: Bool
    let ordinalRange: [Int]
    let originalOrdinalRange: [Int]?
    private let bookmarks: [BibleReaderPreparedBibleBookmarkInput]
    private let aiDocMarkers: [BibleReaderAIDocMarkerIdentity]
    let memorizedOrdinals: [Int]
    let targetOrdinals: [Int]
    let chapterReadCount: Int?
    let setupIdentity: BibleReaderPreparationExactText

    init(
        osisBookID: String,
        bookName: String,
        chapter: Int,
        isNewTestament: Bool,
        ordinalRange: [Int],
        originalOrdinalRange: [Int]?,
        bookmarks: [BibleReaderPreparedBibleBookmarkInput],
        aiDocMarkers: [MyDocumentAIDocMarker],
        memorizedOrdinals: [Int],
        targetOrdinals: [Int],
        chapterReadCount: Int?,
        setupIdentity: String
    ) {
        self.osisBookID = BibleReaderPreparationExactText(osisBookID)
        self.bookName = BibleReaderPreparationExactText(bookName)
        self.chapter = chapter
        self.isNewTestament = isNewTestament
        self.ordinalRange = ordinalRange
        self.originalOrdinalRange = originalOrdinalRange
        self.bookmarks = bookmarks
        self.aiDocMarkers = aiDocMarkers.map(BibleReaderAIDocMarkerIdentity.init)
        self.memorizedOrdinals = memorizedOrdinals
        self.targetOrdinals = targetOrdinals
        self.chapterReadCount = chapterReadCount
        self.setupIdentity = BibleReaderPreparationExactText(setupIdentity)
    }
}

/** Persistence-owner values frozen before Bible source preparation leaves the main owner. */
struct BibleReaderBibleDocumentOwnerSnapshot: Sendable {
    let osisBookId: String
    let bookName: String
    let chapter: Int
    let isNewTestament: Bool
    let ordinalRange: [Int]
    let originalOrdinalRange: [Int]?
    let bookmarks: [BibleReaderPreparedBibleBookmarkInput]
    let aiDocMarkers: [MyDocumentAIDocMarker]
    let memorizedOrdinals: [Int]
    let targetOrdinals: [Int]
    let chapterReadCount: Int?
    /// Exact typed identity covering every owner-supplied bridge value.
    let identity: BibleReaderBibleDocumentOwnerIdentity

    /** Combines projected source XML with the already-frozen owner values. */
    func payload(
        loadedChapter: BibleChapterDocumentBuilder.LoadedChapterContent,
        source: BibleReaderPreparedSourceMetadata,
        renderedBookmarks: [BibleBookmarkData]
    ) -> BibleReaderPreparedDocumentPayload {
        let key = "\(osisBookId).\(chapter)"
        return BibleReaderPreparedDocumentPayload(
            osisBookId: osisBookId,
            bookName: bookName,
            chapter: chapter,
            isNewTestament: isNewTestament,
            xml: loadedChapter.xml,
            bookCategory: DocumentCategory.bible.rawValue,
            bookInitials: source.initials,
            addChapter: loadedChapter.addChapter,
            originalOrdinalRange: originalOrdinalRange,
            documentKey: key,
            keyName: "\(bookName) \(chapter)",
            ordinalRange: ordinalRange,
            fragmentOrdinalRange: ordinalRange,
            fragmentKey: "\(source.initials)--\(key)",
            fragmentOsisRef: key,
            annotateRef: key,
            fragmentFeatures: [:],
            commentaryRange: nil,
            moduleName: source.name,
            moduleAbbreviation: source.abbreviation,
            versificationName: source.versificationName,
            language: source.language,
            direction: source.direction,
            hasStrongs: source.hasStrongs,
            bookmarks: renderedBookmarks,
            genericBookmarks: [],
            aiDocMarkers: aiDocMarkers,
            memorizedOrdinals: memorizedOrdinals,
            targetOrdinals: targetOrdinals,
            chapterReadCount: chapterReadCount,
            isNativeHTML: false
        )
    }
}

/** Exact persistence-owner identity for annotations on one generic source key. */
struct BibleReaderGenericDocumentOwnerIdentity: Hashable, Sendable {
    let genericBookmarks: [BibleReaderPreparedGenericBookmarkInput]
    private let aiDocMarkers: [BibleReaderAIDocMarkerIdentity]

    init(
        genericBookmarks: [BibleReaderPreparedGenericBookmarkInput],
        aiDocMarkers: [MyDocumentAIDocMarker]
    ) {
        self.genericBookmarks = genericBookmarks
        self.aiDocMarkers = aiDocMarkers.map(BibleReaderAIDocMarkerIdentity.init)
    }
}

/** Persistence-owner annotation values frozen for one generic source key. */
struct BibleReaderGenericDocumentOwnerSnapshot: Sendable {
    let genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput]
    let aiDocMarkers: [MyDocumentAIDocMarker]
    let identity: BibleReaderGenericDocumentOwnerIdentity

    /** Combines one copied SWORD fragment with owner-confined generic annotations. */
    func payload(
        fragment: SwordRawOSISFragment,
        osisBookId: String,
        bookCategory: String,
        renderedGenericBookmarks: [GenericBookmarkData],
        commentaryRange: ReaderCommentaryRangePayload? = nil
    ) -> BibleReaderPreparedDocumentPayload {
        let source = fragment.source
        let contentRange = fragment.contentOrdinalRange
        let annotateRef = fragment.annotateRef ?? fragment.key
        return BibleReaderPreparedDocumentPayload(
            osisBookId: osisBookId,
            bookName: fragment.keyName,
            chapter: 1,
            isNewTestament: fragment.isNewTestament,
            xml: fragment.xml,
            bookCategory: bookCategory,
            bookInitials: source.initials,
            addChapter: false,
            originalOrdinalRange: nil,
            documentKey: fragment.key,
            keyName: fragment.keyName,
            ordinalRange: [contentRange.lowerBound, contentRange.upperBound],
            fragmentOrdinalRange: fragment.keyOrdinalRange.map {
                [$0.lowerBound, $0.upperBound]
            },
            fragmentKey: fragment.fragmentKey,
            fragmentOsisRef: fragment.osisRef,
            annotateRef: annotateRef,
            fragmentFeatures: fragment.features,
            commentaryRange: commentaryRange,
            moduleName: source.name,
            moduleAbbreviation: source.abbreviation,
            versificationName: source.versification,
            language: source.language,
            direction: source.direction,
            hasStrongs: source.hasStrongs,
            bookmarks: [],
            genericBookmarks: renderedGenericBookmarks,
            aiDocMarkers: aiDocMarkers,
            memorizedOrdinals: [],
            targetOrdinals: [],
            chapterReadCount: nil,
            isNativeHTML: false
        )
    }

    /** Combines one copied SQLite request with owner-confined generic annotations. */
    func payload(
        request: BibleReaderDocumentPayloadRequest,
        renderedGenericBookmarks: [GenericBookmarkData]
    ) -> BibleReaderPreparedDocumentPayload {
        let key = request.documentKey ?? "\(request.osisBookId).\(request.chapter)"
        let initials = request.bookInitials ?? request.osisBookId
        let annotateRef = request.annotateRef ?? key
        let ordinalRange = request.ordinalRangeOverride
        return BibleReaderPreparedDocumentPayload(
            osisBookId: request.osisBookId,
            bookName: request.bookName,
            chapter: request.chapter,
            isNewTestament: request.isNewTestament,
            xml: request.xml,
            bookCategory: request.bookCategory,
            bookInitials: initials,
            addChapter: request.addChapter,
            originalOrdinalRange: request.originalOrdinalRange,
            documentKey: key,
            keyName: request.keyName ?? request.bookName,
            ordinalRange: ordinalRange,
            fragmentOrdinalRange: request.fragmentOrdinalRange,
            fragmentKey: request.fragmentKey ?? "\(initials)--\(key)",
            fragmentOsisRef: request.fragmentOsisRef ?? key,
            annotateRef: annotateRef,
            fragmentFeatures: request.fragmentFeatures,
            commentaryRange: request.commentaryRange,
            moduleName: request.moduleName ?? initials,
            moduleAbbreviation: request.moduleAbbreviation ?? initials,
            versificationName: request.versificationName,
            language: request.language,
            direction: request.direction,
            hasStrongs: request.sourceHasStrongs ?? false,
            bookmarks: [],
            genericBookmarks: renderedGenericBookmarks,
            aiDocMarkers: aiDocMarkers,
            memorizedOrdinals: [],
            targetOrdinals: [],
            chapterReadCount: nil,
            isNativeHTML: false
        )
    }

    /** Serializes one immutable EPUB fragment with the exact copied generic annotations. */
    func epubEncodedJSON(
        bookName: String,
        bookInitials: String,
        content: EpubReader.Content,
        language: String,
        renderedGenericBookmarks: [GenericBookmarkData]
    ) -> String? {
        guard genericBookmarkInputs.map({ $0.id.uuidString })
                == renderedGenericBookmarks.map(\.id),
              let bookmarkObjects = Self.encodedObjects(renderedGenericBookmarks) else {
            return nil
        }
        let ordinalRange = [content.ordinalRange.lowerBound, content.ordinalRange.upperBound]
        let direction = Self.textDirection(language: language)
        let document: [String: Any] = [
            "id": BibleReaderDocumentPayloadFactory.androidDocumentID(
                bookInitials: bookInitials,
                key: content.persistedKey
            ),
            "type": "osis",
            "osisFragment": [
                "xml": content.html,
                "key": "\(bookInitials)--\(content.persistedKey)",
                "keyName": content.title,
                "v11n": NSNull(),
                "bookCategory": DocumentCategory.generalBook.rawValue,
                "bookInitials": bookInitials,
                "bookAbbreviation": bookName,
                "osisRef": content.persistedKey,
                "isNewTestament": false,
                "features": [String: Any](),
                "hasStrongs": false,
                "ordinalRange": ordinalRange,
                "language": language,
                "direction": direction,
            ] as [String: Any],
            "bookInitials": bookInitials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": bookName,
            "bookName": bookName,
            "key": content.persistedKey,
            "v11n": NSNull(),
            "osisRef": content.persistedKey,
            "annotateRef": content.persistedKey,
            "genericBookmarks": bookmarkObjects,
            "ordinalRange": ordinalRange,
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull(),
            "aiDocMarkers": aiDocMarkers.map {
                BibleReaderMyDocumentCoordinator.markerJSON($0)
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodedObjects<Value: Encodable>(_ values: [Value]) -> [Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var objects: [Any] = []
        objects.reserveCapacity(values.count)
        for value in values {
            guard let data = try? encoder.encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            objects.append(object)
        }
        return objects
    }

    private static func textDirection(language: String) -> String {
        let primary = language.split(separator: "-").first?.lowercased() ?? ""
        return ["ar", "fa", "he", "iw", "ps", "ur", "yi"].contains(primary) ? "rtl" : "ltr"
    }
}

/** Source capture and presentation metadata retained through Bible projection. */
enum BibleReaderBibleChapterSourceCapture: Sendable {
    case sword(
        BibleChapterDocumentBuilder.CapturedChapter,
        BibleReaderPreparedSourceMetadata,
        BibleReaderPreparedBibleChapterStructure
    )
    case sqlite(
        SQLiteBibleChapterDocumentBuilder.CapturedChapter,
        BibleReaderPreparedSourceMetadata,
        BibleReaderPreparedBibleChapterStructure
    )
}

/** Projected chapter plus its immutable source metadata, ready for bridge encoding. */
struct BibleReaderProjectedBibleChapter: Sendable {
    let loadedChapter: BibleChapterDocumentBuilder.LoadedChapterContent
    let source: BibleReaderPreparedSourceMetadata
    let structure: BibleReaderPreparedBibleChapterStructure
}

/** Worker-enriched Bible annotations plus every mutable source dependency they consumed. */
struct BibleReaderPreparedBibleAnnotations: Sendable {
    let bookmarks: [BibleBookmarkData]
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Bridge-ready Bible document and projected range metadata returned to the main publisher. */
struct BibleReaderEncodedBibleChapter: Sendable {
    let documentJSON: String
    let loadedChapter: BibleChapterDocumentBuilder.LoadedChapterContent
    let structure: BibleReaderPreparedBibleChapterStructure
    let ownerIdentity: BibleReaderBibleDocumentOwnerIdentity
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

extension BibleReaderBibleChapterSourceCapture {
    /** Performs only source-independent chapter projection. */
    func projectedChapter() -> BibleReaderProjectedBibleChapter? {
        switch self {
        case .sword(let capture, let source, let structure):
            guard let loaded = BibleChapterDocumentBuilder.projectChapter(capture) else { return nil }
            return BibleReaderProjectedBibleChapter(
                loadedChapter: loaded,
                source: source,
                structure: structure
            )
        case .sqlite(let capture, let source, let structure):
            guard let loaded = SQLiteBibleChapterDocumentBuilder.projectChapter(capture) else { return nil }
            return BibleReaderProjectedBibleChapter(
                loadedChapter: loaded,
                source: source,
                structure: structure
            )
        }
    }
}

/**
 Complete copied values required to encode one OSIS-backed Vue reader document.

 The main owner resolves persistence-backed annotations and progress before constructing this value.
 Native source capture and XML projection can then attach their immutable result, and the preparation
 worker can serialize the complete document without touching SwiftData, controller state, or native
 handles.
 */
struct BibleReaderPreparedDocumentPayload: Sendable {
    let osisBookId: String
    let bookName: String
    let chapter: Int
    let isNewTestament: Bool
    let xml: String
    let bookCategory: String
    let bookInitials: String
    let addChapter: Bool
    let originalOrdinalRange: [Int]?
    let documentKey: String
    let keyName: String
    let ordinalRange: [Int]?
    let fragmentOrdinalRange: [Int]?
    let fragmentKey: String
    let fragmentOsisRef: String
    let annotateRef: String
    let fragmentFeatures: [String: String]
    let commentaryRange: ReaderCommentaryRangePayload?
    let moduleName: String
    let moduleAbbreviation: String
    let versificationName: String?
    let language: String
    let direction: String
    let hasStrongs: Bool
    let bookmarks: [BibleBookmarkData]
    let genericBookmarks: [GenericBookmarkData]
    let aiDocMarkers: [MyDocumentAIDocMarker]
    let memorizedOrdinals: [Int]
    let targetOrdinals: [Int]
    let chapterReadCount: Int?
    let isNativeHTML: Bool

    /**
     Serializes the frozen document with Android's existing Vue field identities.

     - Returns: Deterministically key-sorted JSON, or nil when a typed nested payload cannot encode
       or the assembled value is not valid JSON.
     - Side effects: Performs in-memory encoding and logs a bounded source identity on failure.
     - Failure modes: A Bible document without a versification or ordinal range fails closed.
     */
    func encodedJSON() -> String? {
        let isBibleDocument = bookCategory == DocumentCategory.bible.rawValue
        guard !isBibleDocument || (versificationName != nil && ordinalRange != nil) else {
            preparedDocumentLogger.error(
                "Refusing prepared Bible payload without source range for \(self.osisBookId, privacy: .public).\(self.chapter)"
            )
            return nil
        }

        guard let bookmarkObjects = Self.jsonObjects(bookmarks),
              let genericBookmarkObjects = Self.jsonObjects(genericBookmarks) else {
            preparedDocumentLogger.error(
                "Failed to encode nested annotations for \(self.bookInitials, privacy: .public) \(self.documentKey, privacy: .public)"
            )
            return nil
        }
        let markerObjects = aiDocMarkers.map {
            BibleReaderMyDocumentCoordinator.markerJSON(
                $0,
                targetVersification: isBibleDocument ? versificationName : nil
            )
        }
        let commentaryRangeObject: Any
        if let commentaryRange {
            guard let object = Self.jsonObject(commentaryRange) else {
                preparedDocumentLogger.error("Failed to encode prepared commentary range")
                return nil
            }
            commentaryRangeObject = object
        } else {
            commentaryRangeObject = NSNull()
        }
        var document: [String: Any] = [
            "id": BibleReaderDocumentPayloadFactory.androidDocumentID(
                bookInitials: bookInitials,
                key: documentKey
            ),
            "type": isBibleDocument ? "bible" : "osis",
            "osisFragment": osisFragmentObject,
            "bookInitials": bookInitials,
            "bookCategory": bookCategory,
            "bookAbbreviation": moduleAbbreviation,
            "bookName": moduleName,
            "key": documentKey,
            "v11n": versificationName ?? NSNull(),
            "osisRef": annotateRef,
            "annotateRef": annotateRef,
            "genericBookmarks": genericBookmarkObjects,
            "ordinalRange": ordinalRange ?? NSNull(),
            "isNativeHtml": isNativeHTML,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": false,
            "isAiDocument": false,
            "myDocumentPageId": NSNull(),
            "sourcePromptId": NSNull(),
            "sourcePromptName": NSNull(),
            "sourceModelName": NSNull(),
            "aiDocMarkers": markerObjects,
            "commentaryRange": commentaryRangeObject,
        ]
        if isBibleDocument {
            document["bookmarks"] = bookmarkObjects
            document["bibleBookName"] = bookName
            document["addChapter"] = addChapter
            document["chapterNumber"] = chapter
            document["originalOrdinalRange"] = originalOrdinalRange ?? NSNull()
            document["memorizedOrdinals"] = memorizedOrdinals
            document["targetOrdinals"] = targetOrdinals
            if let chapterReadCount {
                document["chapterReadCount"] = chapterReadCount
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            preparedDocumentLogger.error(
                "Failed to encode prepared document \(self.bookInitials, privacy: .public) \(self.documentKey, privacy: .public)"
            )
            return nil
        }
        return json
    }

    /** Nested OSIS fragment dictionary assembled only from copied request values. */
    private var osisFragmentObject: [String: Any] {
        [
            "xml": xml,
            "key": fragmentKey,
            "keyName": keyName,
            "v11n": versificationName ?? NSNull(),
            "bookCategory": bookCategory,
            "bookInitials": bookInitials,
            "bookAbbreviation": moduleAbbreviation,
            "osisRef": fragmentOsisRef,
            "isNewTestament": isNewTestament,
            "features": fragmentFeatures,
            "hasStrongs": hasStrongs,
            "ordinalRange": fragmentOrdinalRange ?? NSNull(),
            "language": language,
            "direction": direction,
        ]
    }

    /** Converts one typed nested bridge value into a JSON-compatible Foundation object. */
    private static func jsonObject<Value: Encodable>(_ value: Value) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /** Encodes a nested collection atomically so one invalid member fails the whole document. */
    private static func jsonObjects<Value: Encodable>(_ values: [Value]) -> [Any]? {
        var objects: [Any] = []
        objects.reserveCapacity(values.count)
        for value in values {
            guard let object = jsonObject(value) else { return nil }
            objects.append(object)
        }
        return objects
    }
}
