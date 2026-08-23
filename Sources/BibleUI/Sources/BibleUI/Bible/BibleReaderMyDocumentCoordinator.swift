// BibleReaderMyDocumentCoordinator.swift -- My Documents reader state and payload assembly

import BibleCore
import BibleView
import Foundation
import SwordKit

/**
 Owns reader-local My Documents page identity and WebView payload assembly.

 Android presents My Documents as generated general-book modules while raw editable content is
 fetched and saved through bridge calls. This coordinator keeps the iOS reader aligned with that
 contract without making `BibleReaderController` own the active page slots or duplicate the
 `OsisDocument` JSON shape. The type is intentionally value-scoped to one reader pane and does not
 perform SwiftData fetches, bridge emission, pasteboard writes, or persistence.

 - Side effects: Mutates only its active document/page identity.
 - Failure modes: Document JSON serialization returns `nil` if the assembled payload cannot be
   encoded; callers should avoid emitting invalid placeholder JSON.
 - Note: Content-type rendering delegates to BibleCore's pinned CommonMark/GFM renderer and emits
   Android's native-HTML wrappers; OSIS content passes through unchanged.
 */
struct BibleReaderMyDocumentCoordinator {
    /// JSword `rtol.txt` language identifiers that default to right-to-left without a script tag.
    private static let rightToLeftLanguages: Set<String> = ["ar", "fa", "he", "syr", "ur", "uig"]

    /// JSword `rtol.txt` script identifiers; an explicit script takes precedence over language.
    private static let rightToLeftScripts: Set<String> = [
        "Arab", "Armi", "Avst", "Hebr", "Hung", "Lydi", "Mand", "Mani", "Merc", "Mero",
        "Mong", "Mroo", "Narb", "Nbat", "Nkoo", "Orkh", "Palm", "Phli", "Phlp", "Phlv",
        "Phnx", "Prti", "Samr", "Sarb", "Syrc", "Syre", "Syrj", "Syrn", "Tfng", "Thaa",
    ]

    /// Active local My Documents document initials currently rendered in the pane.
    private var activeBookInitials: String?

    /// Active local My Documents page key currently rendered in the pane.
    private var activePageKey: String?

    /**
     Records the My Documents page currently visible in the reader.

     - Parameters:
       - bookInitials: Android-compatible generated general-book initials for the document.
       - pageKey: Page key scoped to `bookInitials`.
     - Side effects: Replaces the active document/page identity for this coordinator.
     - Failure modes: None; callers are responsible for resolving the page before recording it.
     */
    mutating func setActivePage(bookInitials: String, pageKey: String) {
        activeBookInitials = bookInitials
        activePageKey = pageKey
    }

    /**
     Clears any active My Documents page identity.

     - Side effects: Removes the active document/page identity for this coordinator.
     - Failure modes: None.
     */
    mutating func clearActivePage() {
        activeBookInitials = nil
        activePageKey = nil
    }

    /**
     Clears active My Documents state when rendered content moves away from that local document.

     `BibleReaderController.setRenderedContentState` calls this for every native content emission.
     The active My Documents page is preserved only when the rendered content remains the same
     generated general-book module, matching the previous controller-owned reload/delete guard.

     - Parameters:
       - category: Rendered document category being sent to the reader.
       - moduleName: Rendered module/document initials, if any.
     - Side effects: Clears active identity when the rendered content is not the active My Document.
     - Failure modes: None.
     */
    mutating func clearActivePageUnless(category: DocumentCategory, moduleName: String?) {
        if category != .generalBook || !Self.javaExactMatch(moduleName, activeBookInitials) {
            clearActivePage()
        }
    }

    /**
     Returns the active page key only when it belongs to the requested My Documents collection.

     - Parameter bookInitials: Android-compatible generated general-book initials to match.
     - Returns: Active page key for the document, or `nil` when another document/category is active.
     - Side effects: None.
     - Failure modes: None.
     */
    func activePageKey(for bookInitials: String) -> String? {
        Self.javaExactMatch(activeBookInitials, bookInitials) ? activePageKey : nil
    }

    /**
     Checks whether an AI page action belongs to the active My Documents collection.

     - Parameter context: Store-validated AI page action context.
     - Returns: `true` when the action's document initials match the active document.
     - Side effects: None.
     - Failure modes: None.
     */
    func isActiveDocument(_ context: MyDocumentAIPageActionContext) -> Bool {
        Self.javaExactMatch(activeBookInitials, context.bookInitials)
    }

    /**
     Checks whether an AI page action targets the exact active My Documents page.

     - Parameter context: Store-validated AI page action context.
     - Returns: `true` when both document initials and page key match the active page.
     - Side effects: None.
     - Failure modes: None.
     */
    func isActivePage(_ context: MyDocumentAIPageActionContext) -> Bool {
        Self.javaExactMatch(activeBookInitials, context.bookInitials)
          && Self.javaExactMatch(activePageKey, context.pageKey)
    }

    /**
     Builds Android's separate native share subject and body values.

     - Parameter payload: Raw page payload resolved by `MyDocumentStore`.
     - Returns: Subject from the page title and body from raw content, without concatenation.
     - Side effects: None.
     - Failure modes: None.
     */
    func sharePayload(for payload: MyDocumentRawContentPayload) -> MyDocumentSharePayload {
        MyDocumentSharePayload(subject: payload.title, body: payload.content)
    }

    /**
     Builds the Vue.js `OsisDocument` payload for one stored My Documents page.

     - Parameters:
       - document: Parent My Documents collection resolved by Android-compatible initials.
       - page: Page metadata/content to render.
       - metadata: Prompt/model/footer and source-page marker metadata projected by the store.
       - genericBookmarks: Persisted annotations for this exact document initials and page key.
       - bookLocale: Locale used to generate the document book's language metadata. The default uses
         the current app/device locale, matching Android's `Locale.getDefault()` contract.
     - Returns: Sorted-key JSON string for the WebView `add_documents` event, or `nil` if encoding
       fails.
     - Side effects: None.
     - Failure modes: Returns `nil` instead of an empty placeholder object so callers do not emit an
       invalid document payload to Vue.
     */
    func documentJSON(
        document: MyDocument,
        page: MyDocumentPage,
        metadata: MyDocumentReaderMetadata? = nil,
        genericBookmarks: [GenericBookmarkData] = [],
        bookLocale: Locale = .current
    ) -> String? {
        let content = page.pageContent?.content ?? ""
        let renderedContent = MyDocumentContentRenderer.render(content, contentType: page.contentType)
        guard let processed = try? SwordOSISFragmentProcessor.process(
            sourceXML: renderedContent,
            category: .generalBook,
            moduleInitials: document.initials
        ) else {
            return nil
        }
        let sourcePromptId = metadata?.sourcePromptId ?? page.sourcePromptId
        let languageCode = Self.generatedBookLanguageCode(for: bookLocale)
        let direction = Self.textDirection(for: languageCode)
        let ordinalRange = [
            processed.contentOrdinalRange.lowerBound,
            processed.contentOrdinalRange.upperBound,
        ]

        let osisFragment: [String: Any] = [
            "xml": processed.xml,
            "key": "\(document.initials)--\(page.pageKey)",
            "keyName": page.title,
            "v11n": NSNull(),
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookInitials": document.initials,
            "bookAbbreviation": document.initials,
            "osisRef": page.pageKey,
            "isNewTestament": false,
            "features": [String: Any](),
            "hasStrongs": false,
            "ordinalRange": NSNull(),
            "language": languageCode,
            "direction": direction,
        ]

        let renderedDocument: [String: Any] = [
            "id": Self.androidDocumentID(bookInitials: document.initials, key: page.pageKey),
            "type": "osis",
            "osisFragment": osisFragment,
            "bookInitials": document.initials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": document.initials,
            "bookName": document.name,
            "key": page.pageKey,
            "v11n": NSNull(),
            "osisRef": page.pageKey,
            "annotateRef": page.pageKey,
            "genericBookmarks": genericBookmarks.compactMap(Self.jsonObject),
            "ordinalRange": ordinalRange,
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": true,
            "isAiDocument": SwordJavaStringIdentity.equals(document.initials, "AIDocuments"),
            "myDocumentPageId": page.id.uuidString,
            "sourcePromptId": Self.jsonValue(sourcePromptId?.uuidString),
            "sourcePromptName": Self.jsonValue(metadata?.sourcePromptName),
            "sourceModelName": Self.jsonValue(metadata?.sourceModelName),
            "aiDocMarkers": (metadata?.aiDocMarkers ?? []).map { Self.markerJSON($0) },
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: renderedDocument, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /**
     Builds Android's DOM-safe document identifier from exact generated-book identity.

     - Parameters:
       - bookInitials: Generated My Documents book initials.
       - key: Exact page key within the generated book.
     - Returns: `<initials>-<key>` with every non-letter and non-ASCII-digit scalar replaced by `_`.
     - Side effects: None.
     - Failure modes: None; every input scalar maps deterministically to itself or `_`.
     */
    private static func androidDocumentID(bookInitials: String, key: String) -> String {
        "\(bookInitials)-\(key)".unicodeScalars.map { scalar in
            if CharacterSet.letters.contains(scalar) || (48...57).contains(scalar.value) {
                return String(scalar)
            }
            return "_"
        }.joined()
    }

    /** Compares optional persisted identities with Java UTF-16 equality and nil symmetry. */
    private static func javaExactMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            return SwordJavaStringIdentity.equals(lhs, rhs)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    /**
     Converts one typed bridge value into a JSON-compatible nested object.

     - Parameter value: Encodable bridge DTO to embed in the My Documents payload.
     - Returns: Foundation JSON object, or `nil` when encoding or JSON parsing fails.
     - Side effects: None.
     - Failure modes: Invalid DTO encoding is omitted by the caller's compact-map operation.
     */
    private static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? bridgeEncoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /**
     Resolves the language Android associates with a generated My Documents book.

     Android's generated `SwordBookMetaData` writes `Locale.getDefault().language`. Page language is
     intentionally excluded because Android uses that field only for text-to-speech and does not let
     it change the generated book's reader direction.

     - Parameter locale: App/device locale represented by Android's `Locale.getDefault()` value.
     - Returns: The locale's normalized language identifier, or `en` when none is available.
     - Side effects: None; callers inject the locale, and `documentJSON` supplies `.current` by
       default.
     - Failure modes: Missing or empty locale language identifiers fall back to English.
     */
    private static func generatedBookLanguageCode(for locale: Locale) -> String {
        let localeLanguageCode = locale.language.languageCode?.identifier
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localeLanguageCode.isEmpty ? "en" : localeLanguageCode
    }

    /**
     Maps a BCP-47 language identifier to JSword's script-first reader direction.

     - Parameter languageCode: Effective My Documents language identifier.
     - Returns: `rtl` when an explicit script or default language appears in JSword's pinned
       `rtol.txt`; otherwise `ltr`.
     - Side effects: None.
     - Failure modes: Malformed or unknown identifiers safely render left-to-right.
     */
    private static func textDirection(for languageCode: String) -> String {
        let subtags = languageCode.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        let language = subtags.first?.lowercased() ?? ""
        let script = subtags.dropFirst().first { $0.count == 4 }.map { subtag in
            subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
        }
        if let script {
            return rightToLeftScripts.contains(script) ? "rtl" : "ltr"
        }
        return rightToLeftLanguages.contains(language) ? "rtl" : "ltr"
    }

    /**
     One marker range projected into the ordinal/reference domain rendered by a reader pane.

     - Side effects: None after the shared versification resources have loaded.
     - Failure modes: References may be absent for invalid stored KJVA ordinals. A target conversion
       that cannot resolve either endpoint omits the range atomically.
     */
    private struct MarkerRangeProjection {
        /// Inclusive ordinals in the displayed document's versification.
        let ordinalRange: [Int]
        /// Converted first endpoint used for Android-style abbreviated range text.
        let startReference: SwordVersification.Reference?
        /// Converted final endpoint used for Android-style abbreviated range text.
        let endReference: SwordVersification.Reference?
    }

    /**
     Builds Android's `ClientAiDocMarker` JSON shape for one source-page marker.

     - Parameters:
       - marker: Marker whose persisted endpoints belong to Android's KJVA storage domain.
       - targetVersification: Displayed Bible versification, or `nil` for non-Bible documents.
     - Returns: JSON-compatible marker fields in the displayed document's ordinal domain.
     - Side effects: Lazily reads the shared JSword mapping and SWORD canon resources.
     - Failure modes: Missing endpoints or an unavailable target conversion serialize a null range;
       an unaddressable Android public-converter fallback uses ordinal `0` rather than leaking KJVA.
     */
    static func markerJSON(
        _ marker: MyDocumentAIDocMarker,
        targetVersification: String? = nil
    ) -> [String: Any] {
        let range = markerRangeProjection(marker, targetVersification: targetVersification)
        let aiLabelID = "00000000-0000-ab1e-0000-a1d0c00001a1"
        return [
            "id": marker.pageId.uuidString,
            "type": "ai-doc-marker",
            "hashCode": javaUUIDHash(marker.pageId),
            "ordinalRange": range?.ordinalRange ?? NSNull(),
            "offsetRange": NSNull(),
            "labels": [aiLabelID],
            "primaryLabelId": aiLabelID,
            "bookmarkToLabels": [Any](),
            "bookInitials": marker.documentInitials,
            "bookName": marker.documentInitials,
            "bookAbbreviation": marker.documentInitials,
            "createdAt": 0,
            "lastUpdatedOn": 0,
            "text": marker.pageTitle,
            "fullText": marker.pageTitle,
            "notes": NSNull(),
            "notesContentType": NSNull(),
            "hasNote": false,
            "wholeVerse": true,
            "customIcon": "robot",
            "editAction": ["mode": NSNull(), "content": NSNull()],
            "sourcePromptId": jsonValue(marker.sourcePromptId?.uuidString),
            "verseRangeAbbreviated": abbreviatedRange(
                start: range?.startReference,
                end: range?.endReference
            ),
            "title": marker.pageTitle,
            "documentInitials": marker.documentInitials,
            "pageKey": marker.pageKey,
            "sourceBookInitials": jsonValue(marker.sourceBookInitials),
            "sourceBookKey": jsonValue(marker.sourceBookKey),
        ]
    }

    /**
     Projects stored KJVA marker endpoints into an optional displayed versification.

     - Parameters:
       - marker: Marker containing optional KJVA endpoints.
       - targetVersification: Displayed Bible versification, or `nil` to retain KJVA ordinals.
     - Returns: Atomic endpoint projection, or `nil` when either endpoint cannot be converted.
     - Side effects: Lazily reads shared versification resources.
     - Failure modes: Invalid KJVA ordinals fail closed; target references outside the target canon
       retain Android's ordinal-zero sentinel.
     */
    private static func markerRangeProjection(
        _ marker: MyDocumentAIDocMarker,
        targetVersification: String?
    ) -> MarkerRangeProjection? {
        guard let start = marker.kjvOrdinalStart,
              let end = marker.kjvOrdinalEnd else {
            return nil
        }

        guard let targetVersification else {
            return MarkerRangeProjection(
                ordinalRange: [start, end],
                startReference: JSwordKJVAVersification.referenceIncludingIntroductions(
                    ordinal: start
                ).map {
                    SwordVersification.Reference(
                        osisBookId: $0.osisId,
                        chapter: $0.chapter,
                        verse: $0.verse
                    )
                },
                endReference: JSwordKJVAVersification.referenceIncludingIntroductions(
                    ordinal: end
                ).map {
                    SwordVersification.Reference(
                        osisBookId: $0.osisId,
                        chapter: $0.chapter,
                        verse: $0.verse
                    )
                }
            )
        }

        guard let startReference = VersificationMapper.reference(
                  forKJVAOrdinal: start,
                  targetVersification: targetVersification
              ),
              let endReference = VersificationMapper.reference(
                  forKJVAOrdinal: end,
                  targetVersification: targetVersification
              ) else {
            return nil
        }
        return MarkerRangeProjection(
            ordinalRange: [
                SwordVersification.referenceIndex(
                    for: startReference,
                    versification: targetVersification
                ) ?? 0,
                SwordVersification.referenceIndex(
                    for: endReference,
                    versification: targetVersification
                ) ?? 0,
            ],
            startReference: startReference,
            endReference: endReference
        )
    }

    /**
     Formats converted marker endpoints similarly to JSword's abbreviated `VerseRange` output.

     - Parameters:
       - start: First reference in the displayed versification.
       - end: Final reference in the displayed versification.
     - Returns: Compact same-chapter or cross-chapter text, or an empty string without both ends.
     - Side effects: None.
     - Failure modes: Unknown OSIS book abbreviations fall back to their OSIS identifiers.
     */
    private static func abbreviatedRange(
        start: SwordVersification.Reference?,
        end: SwordVersification.Reference?
    ) -> String {
        guard let first = start, let last = end else {
            return ""
        }
        let bookName = JSwordKJVAVersification.shortBookName(osisId: first.osisBookId)
            ?? first.osisBookId
        if first.osisBookId == last.osisBookId, first.chapter == last.chapter {
            if first.verse == last.verse {
                return "\(bookName) \(first.chapter):\(first.verse)"
            }
            return "\(bookName) \(first.chapter):\(first.verse)-\(last.verse)"
        }
        let endBookName = JSwordKJVAVersification.shortBookName(osisId: last.osisBookId)
            ?? last.osisBookId
        return "\(bookName) \(first.chapter):\(first.verse)-\(endBookName) \(last.chapter):\(last.verse)"
    }

    /// Reproduces `java.util.UUID.hashCode()` and Kotlin's non-negative marker hash convention.
    private static func javaUUIDHash(_ uuid: UUID) -> Int {
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        func int64(at offset: Int) -> UInt64 {
            bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let combined = int64(at: 0) ^ int64(at: 8)
        let raw = Int32(bitPattern: UInt32(truncatingIfNeeded: combined >> 32) ^ UInt32(truncatingIfNeeded: combined))
        if raw == .min { return Int(raw) }
        return Int(Swift.abs(raw))
    }

    /// Bridges optional strings into `JSONSerialization` values.
    private static func jsonValue(_ value: String?) -> Any {
        if let value {
            return value
        }
        return NSNull()
    }
}
