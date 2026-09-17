// BibleReaderPreparedMyDocument.swift -- Immutable My Documents bridge preparation

import BibleCore
import BibleView
import Foundation
import SwordKit

/** Exact detached My Documents bookmark-plan identity retained by one preparation request. */
private struct BibleReaderMyDocumentExpectedFragmentIdentity: Hashable, Sendable {
    let documentID: UUID
    let pageID: UUID
    let moduleInitials: BibleReaderPreparationExactText
    let documentName: BibleReaderPreparationExactText
    let key: BibleReaderPreparationExactText
    let title: BibleReaderPreparationExactText
    let contentTypeRawValue: BibleReaderPreparationExactText
    let rawContent: BibleReaderPreparationExactText
    let languageCode: BibleReaderPreparationExactText?
    let ordinalStart: Int
    let ordinalEnd: Int

    init(_ fragment: BibleReaderBookmarkNavigationMyDocumentFragment) {
        documentID = fragment.documentID
        pageID = fragment.pageID
        moduleInitials = BibleReaderPreparationExactText(fragment.moduleInitials)
        documentName = BibleReaderPreparationExactText(fragment.documentName)
        key = BibleReaderPreparationExactText(fragment.key)
        title = BibleReaderPreparationExactText(fragment.title)
        contentTypeRawValue = BibleReaderPreparationExactText(fragment.contentTypeRawValue)
        rawContent = BibleReaderPreparationExactText(fragment.rawContent)
        languageCode = fragment.languageCode.map { BibleReaderPreparationExactText($0) }
        ordinalStart = fragment.ordinalRange.lowerBound
        ordinalEnd = fragment.ordinalRange.upperBound
    }
}

/** Collision-free request identity for one My Documents page preparation. */
struct BibleReaderMyDocumentPreparationRequestIdentity: Hashable, Sendable {
    let requestedInitials: BibleReaderPreparationExactText
    let requestedKey: BibleReaderPreparationExactText
    let selectedOrdinalStart: Int?
    let selectedOrdinalEnd: Int?
    let expectedDocumentID: UUID?
    private let expectedFragment: BibleReaderMyDocumentExpectedFragmentIdentity?

    init(
        requestedInitials: String,
        requestedKey: String,
        selectedOrdinalRange: ClosedRange<Int>?,
        expectedFragment: BibleReaderBookmarkNavigationMyDocumentFragment?,
        expectedDocumentID: UUID? = nil
    ) {
        self.requestedInitials = BibleReaderPreparationExactText(requestedInitials)
        self.requestedKey = BibleReaderPreparationExactText(requestedKey)
        selectedOrdinalStart = selectedOrdinalRange?.lowerBound
        selectedOrdinalEnd = selectedOrdinalRange?.upperBound
        self.expectedDocumentID = expectedDocumentID
        self.expectedFragment = expectedFragment.map(
            BibleReaderMyDocumentExpectedFragmentIdentity.init
        )
    }
}

/** Exact copied identity for one My Documents AI marker. */
private struct BibleReaderPreparedMyDocumentMarkerIdentity: Hashable, Sendable {
    let pageID: UUID
    let documentID: UUID
    let documentInitials: BibleReaderPreparationExactText
    let pageTitle: BibleReaderPreparationExactText
    let pageKey: BibleReaderPreparationExactText
    let kjvaOrdinalStart: Int?
    let kjvaOrdinalEnd: Int?
    let sourcePromptID: UUID?
    let sourceBookInitials: BibleReaderPreparationExactText?
    let sourceBookKey: BibleReaderPreparationExactText?

    init(_ value: MyDocumentAIDocMarker) {
        pageID = value.pageId
        documentID = value.documentId
        documentInitials = BibleReaderPreparationExactText(value.documentInitials)
        pageTitle = BibleReaderPreparationExactText(value.pageTitle)
        pageKey = BibleReaderPreparationExactText(value.pageKey)
        kjvaOrdinalStart = value.kjvOrdinalStart
        kjvaOrdinalEnd = value.kjvOrdinalEnd
        sourcePromptID = value.sourcePromptId
        sourceBookInitials = value.sourceBookInitials.map { BibleReaderPreparationExactText($0) }
        sourceBookKey = value.sourceBookKey.map { BibleReaderPreparationExactText($0) }
    }
}

/** Exact owner identity checked immediately before a prepared My Documents page is published. */
struct BibleReaderPreparedMyDocumentOwnerIdentity: Hashable, Sendable {
    let documentID: UUID
    let documentName: BibleReaderPreparationExactText
    let documentInitials: BibleReaderPreparationExactText
    let pageID: UUID
    let pageTitle: BibleReaderPreparationExactText
    let pageKey: BibleReaderPreparationExactText
    let contentTypeRawValue: BibleReaderPreparationExactText
    let rawContent: BibleReaderPreparationExactText
    let pageSourcePromptID: UUID?
    let sourcePromptID: UUID?
    let sourcePromptName: BibleReaderPreparationExactText?
    let sourceModelName: BibleReaderPreparationExactText?
    private let markers: [BibleReaderPreparedMyDocumentMarkerIdentity]
    private let genericBookmarks: [BibleReaderPreparedGenericBookmarkInput]
    let generatedBookLanguageCode: BibleReaderPreparationExactText

    init(
        documentID: UUID,
        documentName: String,
        documentInitials: String,
        pageID: UUID,
        pageTitle: String,
        pageKey: String,
        contentType: MyDocumentContentType,
        rawContent: String,
        pageSourcePromptID: UUID?,
        metadata: MyDocumentReaderMetadata?,
        genericBookmarks: [BibleReaderPreparedGenericBookmarkInput],
        generatedBookLanguageCode: String
    ) {
        self.documentID = documentID
        self.documentName = BibleReaderPreparationExactText(documentName)
        self.documentInitials = BibleReaderPreparationExactText(documentInitials)
        self.pageID = pageID
        self.pageTitle = BibleReaderPreparationExactText(pageTitle)
        self.pageKey = BibleReaderPreparationExactText(pageKey)
        contentTypeRawValue = BibleReaderPreparationExactText(contentType.rawValue)
        self.rawContent = BibleReaderPreparationExactText(rawContent)
        self.pageSourcePromptID = pageSourcePromptID
        sourcePromptID = metadata?.sourcePromptId
        sourcePromptName = metadata?.sourcePromptName.map { BibleReaderPreparationExactText($0) }
        sourceModelName = metadata?.sourceModelName.map { BibleReaderPreparationExactText($0) }
        markers = (metadata?.aiDocMarkers ?? []).map(BibleReaderPreparedMyDocumentMarkerIdentity.init)
        self.genericBookmarks = genericBookmarks
        self.generatedBookLanguageCode = BibleReaderPreparationExactText(generatedBookLanguageCode)
    }
}

/**
 Immutable copied values required to render and encode one My Documents page off-main.

 Every value here either affects the generated Vue document or establishes its exact persisted
 document/page owner. No SwiftData model, context, controller, or native handle crosses the worker
 boundary. The owner identity enumerates direct content, prompt, marker, and generic-annotation
 values so changes remain visible even when persisted timestamps do not change.
 */
struct BibleReaderPreparedMyDocument: Sendable {
    let documentID: UUID
    let documentName: String
    let documentInitials: String
    let pageID: UUID
    let pageTitle: String
    let pageKey: String
    let contentType: MyDocumentContentType
    let rawContent: String
    let pageSourcePromptID: UUID?
    let metadata: MyDocumentReaderMetadata?
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput]
    let genericBookmarks: [GenericBookmarkData]
    let generatedBookLanguageCode: String
    let ownerIdentity: BibleReaderPreparedMyDocumentOwnerIdentity

    init(
        documentID: UUID,
        documentName: String,
        documentInitials: String,
        pageID: UUID,
        pageTitle: String,
        pageKey: String,
        contentType: MyDocumentContentType,
        rawContent: String,
        pageSourcePromptID: UUID?,
        metadata: MyDocumentReaderMetadata?,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput],
        genericBookmarks: [GenericBookmarkData],
        generatedBookLanguageCode: String
    ) {
        self.documentID = documentID
        self.documentName = documentName
        self.documentInitials = documentInitials
        self.pageID = pageID
        self.pageTitle = pageTitle
        self.pageKey = pageKey
        self.contentType = contentType
        self.rawContent = rawContent
        self.pageSourcePromptID = pageSourcePromptID
        self.metadata = metadata
        self.sourceDependencies = sourceDependencies
        self.genericBookmarkInputs = genericBookmarkInputs
        self.genericBookmarks = genericBookmarks
        self.generatedBookLanguageCode = Self.normalizedLanguageCode(generatedBookLanguageCode)
        ownerIdentity = BibleReaderPreparedMyDocumentOwnerIdentity(
            documentID: documentID,
            documentName: documentName,
            documentInitials: documentInitials,
            pageID: pageID,
            pageTitle: pageTitle,
            pageKey: pageKey,
            contentType: contentType,
            rawContent: rawContent,
            pageSourcePromptID: pageSourcePromptID,
            metadata: metadata,
            genericBookmarks: genericBookmarkInputs,
            generatedBookLanguageCode: Self.normalizedLanguageCode(generatedBookLanguageCode)
        )
    }

    /** Renders copied page content and serializes Android's existing generated-book payload. */
    func encodedJSON() -> String? {
        guard genericBookmarkInputs.map({ $0.id.uuidString }) == genericBookmarks.map(\.id) else {
            return nil
        }
        let renderedContent = MyDocumentContentRenderer.render(rawContent, contentType: contentType)
        guard let processed = try? SwordOSISFragmentProcessor.process(
            sourceXML: renderedContent,
            category: .generalBook,
            moduleInitials: documentInitials
        ) else {
            return nil
        }
        let ordinalRange = [
            processed.contentOrdinalRange.lowerBound,
            processed.contentOrdinalRange.upperBound,
        ]
        let osisFragment: [String: Any] = [
            "xml": processed.xml,
            "key": "\(documentInitials)--\(pageKey)",
            "keyName": pageTitle,
            "v11n": NSNull(),
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookInitials": documentInitials,
            "bookAbbreviation": documentInitials,
            "osisRef": pageKey,
            "isNewTestament": false,
            "features": [String: Any](),
            "hasStrongs": false,
            "ordinalRange": NSNull(),
            "language": generatedBookLanguageCode,
            "direction": Self.textDirection(for: generatedBookLanguageCode),
        ]
        let sourcePromptID = metadata?.sourcePromptId ?? pageSourcePromptID
        let renderedDocument: [String: Any] = [
            "id": Self.androidDocumentID(bookInitials: documentInitials, key: pageKey),
            "type": "osis",
            "osisFragment": osisFragment,
            "bookInitials": documentInitials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": documentInitials,
            "bookName": documentName,
            "key": pageKey,
            "v11n": NSNull(),
            "osisRef": pageKey,
            "annotateRef": pageKey,
            "genericBookmarks": genericBookmarks.compactMap(Self.jsonObject),
            "ordinalRange": ordinalRange,
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": true,
            "isAiDocument": SwordJavaStringIdentity.equals(documentInitials, "AIDocuments"),
            "myDocumentPageId": pageID.uuidString,
            "sourcePromptId": Self.jsonValue(sourcePromptID?.uuidString),
            "sourcePromptName": Self.jsonValue(metadata?.sourcePromptName),
            "sourceModelName": Self.jsonValue(metadata?.sourceModelName),
            "aiDocMarkers": (metadata?.aiDocMarkers ?? []).map {
                BibleReaderMyDocumentCoordinator.markerJSON($0)
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: renderedDocument,
            options: [.sortedKeys]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /** Normalizes the generated-book language copied from the app locale. */
    private static func normalizedLanguageCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "en" : trimmed
    }

    /** Builds Android's DOM-safe `<initials>-<key>` identity. */
    private static func androidDocumentID(bookInitials: String, key: String) -> String {
        "\(bookInitials)-\(key)".unicodeScalars.map { scalar in
            CharacterSet.letters.contains(scalar) || (48...57).contains(scalar.value)
                ? String(scalar) : "_"
        }.joined()
    }

    /** Maps JSword's pinned script/language sets to a generated-book text direction. */
    private static func textDirection(for languageCode: String) -> String {
        let rightToLeftLanguages: Set<String> = ["ar", "fa", "he", "syr", "ur", "uig"]
        let rightToLeftScripts: Set<String> = [
            "Arab", "Armi", "Avst", "Hebr", "Hung", "Lydi", "Mand", "Mani", "Merc", "Mero",
            "Mong", "Mroo", "Narb", "Nbat", "Nkoo", "Orkh", "Palm", "Phli", "Phlp", "Phlv",
            "Phnx", "Prti", "Samr", "Sarb", "Syrc", "Syre", "Syrj", "Syrn", "Tfng", "Thaa",
        ]
        let subtags = languageCode.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map(String.init)
        let language = subtags.first?.lowercased() ?? ""
        let script = subtags.dropFirst().first { $0.count == 4 }.map {
            $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
        }
        if let script {
            return rightToLeftScripts.contains(script) ? "rtl" : "ltr"
        }
        return rightToLeftLanguages.contains(language) ? "rtl" : "ltr"
    }

    /** Converts one typed nested bridge value into a JSON-compatible object. */
    private static func jsonObject<Value: Encodable>(_ value: Value) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /** Bridges an optional string into a JSON-compatible nullable value. */
    private static func jsonValue(_ value: String?) -> Any {
        if let value {
            return value
        }
        return NSNull()
    }
}
