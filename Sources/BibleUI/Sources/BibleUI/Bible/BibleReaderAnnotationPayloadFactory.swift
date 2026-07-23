import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Resolved source context for one non-Bible bookmark.

 The value is backend-neutral so SWORD modules, My Documents, and EPUB adapters can all provide the
 same Android `ClientGenericBookmark` fields without substituting the active reader document.
 */
struct GenericBookmarkSourceContent {
    /// User-visible source document name.
    let bookName: String
    /// Compact source document abbreviation.
    let bookAbbreviation: String
    /// User-visible resolved key name.
    let keyName: String
    /// Complete visible text used by Android-compatible UTF-16 offset slicing.
    let plainText: String
    /// Optional render context supplied to Vue.
    let osisFragment: OsisFragment?

    /**
     Creates a complete stored-source projection.

     - Parameters:
       - bookName: User-visible source document name.
       - bookAbbreviation: Compact source document abbreviation.
       - keyName: User-visible resolved key name.
       - plainText: Complete visible source text used for selection projection.
       - osisFragment: Optional whole-page render context for Vue.
     - Side effects: None.
     - Failure modes: None; source lookup validates provenance before constructing this value.
     */
    init(
        bookName: String,
        bookAbbreviation: String,
        keyName: String,
        plainText: String,
        osisFragment: OsisFragment?
    ) {
        self.bookName = bookName
        self.bookAbbreviation = bookAbbreviation
        self.keyName = keyName
        self.plainText = plainText
        self.osisFragment = osisFragment
    }
}

/**
 Couples resolved generic source metadata with the exact per-anchor text sequence Android uses.

 `GenericBookmarkSourceContent` remains backend-neutral for My Documents and EPUB providers. This
 wrapper adds the ordered `BVA` text segments available from generic SWORD fragments so UTF-16 start
 and end offsets apply to the first and last selected anchors rather than to one flattened string.
 */
private struct ResolvedGenericBookmarkSourceContent {
    /// Backend-neutral names, plain text, and optional bridge fragment.
    let content: GenericBookmarkSourceContent
    /// Ordered text segments for the bookmark's persisted local ordinal range.
    let selectedTexts: [String]
}

/**
 Text segments used by Android's Bookmark list to emphasize the persisted selection.

 Android keeps the text before and after a bookmark selection separate from the selected text, then
 renders only the selected segment in bold. This value carries that semantic structure into SwiftUI
 without reparsing generated HTML or resolving bookmark content a second time in the presentation
 layer.

 Inputs: source text split by verse/anchor plus persisted UTF-16 offsets
 Outputs: prefix, selected text, suffix, and the normalized complete preview
 Side effects: none
 Failure modes: missing source content produces `empty`; invalid offsets are clamped
 */
struct BookmarkListTextProjection: Equatable {
    /// Text before the selected range in the first source segment.
    let prefix: String

    /// Selected range rendered with emphasis by the Bookmark list.
    let selectedText: String

    /// Text after the selected range in the final source segment.
    let suffix: String

    /// Complete normalized row preview matching Android's `fullText` value.
    let fullText: String

    /// Empty projection used when the persisted source cannot be resolved.
    static let empty = BookmarkListTextProjection(
        prefix: "",
        selectedText: "",
        suffix: "",
        fullText: ""
    )
}

/**
 Projects reader bookmark, label, My Notes, and StudyPad models into Vue bridge DTOs.

 `BibleReaderController` owns navigation state and bridge event routing; this factory owns the
 serialization contract for annotation-like reader data. Keeping projection logic here prevents
 bookmark, label, and StudyPad payloads from drifting as controller responsibilities are extracted.

 Inputs:
- active module state used to resolve JSword/SWORD-style ordinals and verse text
- the current reader book used when older bookmarks do not carry an explicit book
- the current module initials used as a fallback for active-document projection
- the effective book list for OSIS lookups

 Outputs:
 - typed `BibleView` bridge DTOs and document payload DTOs consumed by Vue.js

 Side effects:
 - may temporarily move the active SWORD module cursor while resolving verse text

 Failure modes:
 - missing or deleted label relationships are omitted from optional relationship payloads
 - invalid bookmark end ordinals collapse to the start verse, preserving existing behavior
 */
struct BibleReaderAnnotationPayloadFactory {
    /// Current book name used as the fallback for legacy bookmarks without a stored book.
    private let currentBook: String
    /// Active module initials emitted to the web bridge.
    private let activeModuleName: String
    /// Active SWORD module used for ordinal and verse-text projection.
    private let activeModule: SwordModule?
    /// Resolves an installed SWORD module strictly by stored initials.
    private let sourceModuleResolver: (String) -> SwordModule?
    /// Resolves non-SWORD source content strictly by stored initials and key.
    private let genericSourceResolver: (String, String) -> GenericBookmarkSourceContent?
    /// Active-module-aware catalog used for OSIS lookup and ordinal projection.
    private let bookCatalog: BibleReaderBookCatalog
    /// Synthetic unlabeled label identifier required by the web client.
    private let unlabeledLabelID: String
    /**
     Selects the ordinal domain used for Bible bookmark bridge payloads.

     Normal reader documents highlight against the active module's rendered ordinals, while
     Android's My Notes fake document renders bookmark rows in KJVA ordinals. Keeping the choice
     explicit prevents `ordinalRange` and `originalOrdinalRange` from drifting back into the same
     domain.

     - Side effects: None.
     - Failure modes: None.
     */
    private enum BibleBookmarkOrdinalProjection {
        /// Project visible row ordinals into the active reader module when possible.
        case activeModule
        /// Project visible row ordinals into Android's KJVA bookmark domain.
        case kjva
    }

    /**
     Normalizes Swift hash values into the non-negative `hashCode` shape expected by BibleView.

     The bridge already used `abs(id.hashValue)` for StudyPad DOM keys, so this preserves that
     contract for all ordinary values while handling `Int.min`, whose absolute value cannot be
     represented and would otherwise trap at runtime.

     - Parameter hashValue: Swift hash value produced for a bridge identifier.
     - Returns: A non-negative hash code, mapping `Int.min` to `Int.max`.
     - Side effects: None.
     - Failure modes: None; specifically avoids the `abs(Int.min)` overflow trap.
     */
    static func normalizedBridgeHashCode(from hashValue: Int) -> Int {
        hashValue == Int.min ? Int.max : abs(hashValue)
    }

    /**
     Creates a bookmark and StudyPad payload factory for the current reader state.

     - Parameters:
       - currentBook: Display name for the reader's current Bible book.
       - activeModuleName: Initials/name of the active module.
       - activeModule: Active SWORD module, if one is loaded.
       - sourceModuleResolver: Installed-module lookup keyed by stored initials. When omitted, only
         the matching active module is visible to the factory.
       - genericSourceResolver: My Documents/EPUB lookup keyed by stored initials and key.
       - bookCatalog: Active-module-aware catalog boundary for OSIS and ordinal projection.
       - unlabeledLabelID: Stable identifier for the synthetic unlabeled label.
     - Side effects: None during initialization.
     - Failure modes: None; per-payload methods handle missing model relationships.
     */
    init(
        currentBook: String,
        activeModuleName: String,
        activeModule: SwordModule?,
        sourceModuleResolver: ((String) -> SwordModule?)? = nil,
        genericSourceResolver: @escaping (String, String) -> GenericBookmarkSourceContent? = { _, _ in nil },
        bookCatalog: BibleReaderBookCatalog,
        unlabeledLabelID: String
    ) {
        self.currentBook = currentBook
        self.activeModuleName = activeModuleName
        self.activeModule = activeModule
        self.sourceModuleResolver = sourceModuleResolver ?? { initials in
            initials == activeModuleName ? activeModule : nil
        }
        self.genericSourceResolver = genericSourceResolver
        self.bookCatalog = bookCatalog
        self.unlabeledLabelID = unlabeledLabelID
    }

    /**
     Builds the typed Bible bookmark bridge payload consumed by Vue.js.

     - Parameter bookmark: SwiftData Bible bookmark model to project.
     - Returns: A key-preserving bridge DTO; nullable fields encode as explicit JSON `null`.
     - Side effects: reads verse text from the active SWORD module when available.
     - Failure modes: missing label relationships are filtered and replaced with the synthetic
       unlabeled relation required by the web client.
     */
    func bookmarkJSON(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        bibleBookmarkJSON(bookmark, editAction: EditActionData())
    }

    /**
     Builds a My Notes bookmark payload with the same shape as a standard Bible bookmark.

     - Parameter bookmark: Bible bookmark rendered in the chapter My Notes document.
     - Returns: The bookmark DTO expected by the reader web client.
     - Side effects: reads verse text from the active SWORD module when available.
     - Failure modes: same as `bookmarkJSON(_:)`.
     */
    func bookmarkJSONForMyNotes(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        bibleBookmarkJSON(bookmark, editAction: EditActionData(), ordinalProjection: .kjva)
    }

    /**
     Builds a typed Bible bookmark payload for a StudyPad document.

     - Parameter bookmark: Bible bookmark attached to the active StudyPad label.
     - Returns: A bridge DTO including StudyPad edit-action metadata.
     - Side effects: reads verse text from the active SWORD module when available.
     - Failure modes: missing label relationships are filtered through
       `BookmarkLabelSerializationSupport`.
     */
    func bookmarkJSONForStudyPad(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        bibleBookmarkJSON(bookmark, editAction: editActionData(bookmark.editAction))
    }

    /**
     Builds a typed generic bookmark payload for StudyPad and bookmark update events.

     - Parameter bookmark: Generic bookmark model attached to non-Bible content.
     - Returns: The generic bookmark DTO expected by Vue.js.
     - Side effects: None.
     - Failure modes: missing label relationships are filtered through
       `BookmarkLabelSerializationSupport`.
     */
    func genericBookmarkJSONForStudyPad(_ bookmark: GenericBookmark) -> GenericBookmarkData {
        genericBookmarkJSONForStudyPad(
            bookmark,
            resolvedSource: genericSourceContent(for: bookmark)
        )
    }

    /**
     Resolves the exact Bible text presentation used by Android's Bookmark list.

     - Parameter bookmark: Persisted Bible bookmark whose active-module text should be displayed.
     - Returns: Prefix, selected text, suffix, and full preview with UTF-16 offsets clamped safely.
     - Side effects: May move the active SWORD module cursor while loading verse text.
     - Failure modes: Missing modules or unresolved verses return an empty projection.
     */
    func bookmarkListTextProjection(_ bookmark: BibleBookmark) -> BookmarkListTextProjection {
        let bookmarkBook = bookmark.book ?? currentBook
        let range = bibleBookmarkRangeProjection(
            bookName: bookmarkBook,
            sourceStartOrdinal: bookmark.ordinalStart,
            sourceEndOrdinal: bookmark.ordinalEnd,
            kjvStartOrdinal: bookmark.kjvOrdinalStart,
            kjvEndOrdinal: bookmark.kjvOrdinalEnd,
            ordinalProjection: .activeModule
        )
        let hasSourceModule = !sourceModuleMetadata(for: bookmark).initials.isEmpty
        return Self.bookmarkTextProjection(
            sourceTexts: loadVerseTexts(for: range),
            startOffset: bookmark.startOffset,
            endOffset: bookmark.endOffset,
            wholeVerse: bookmark.wholeVerse || !hasSourceModule
        ) ?? .empty
    }

    /**
     Resolves the exact generic text presentation used by Android's Bookmark list.

     - Parameter bookmark: Persisted generic bookmark carrying its source identity and offsets.
     - Returns: Prefix, selected text, suffix, and full preview from the stored source.
     - Side effects: May move a resolved SWORD source cursor while loading its exact key.
     - Failure modes: Missing source content returns an empty projection; whole-page sources return
       Android's first 200 UTF-16 code-unit preview.
     */
    func bookmarkListTextProjection(_ bookmark: GenericBookmark) -> BookmarkListTextProjection {
        genericBookmarkListTextProjection(
            bookmark: bookmark,
            sourceTexts: genericSourceContent(for: bookmark)?.selectedTexts ?? []
        )
    }

    /**
     Builds the creation-event payload directly from the immutable generic SWORD source seed.

     The persisted bookmark supplies identity, labels, timestamps, and note state; the seed supplies
     exact source category, key metadata, raw OSIS, ordered anchor text, and UTF-16 selection
     context. A mismatched seed fails closed to stored identifiers instead of borrowing active Bible
     metadata.

     - Parameters:
       - bookmark: Generic bookmark just persisted from `sourceSeed`.
       - sourceSeed: Validated generic SWORD source and selection contract.
     - Returns: Android-compatible generic bookmark bridge payload.
     - Side effects: None; no source reload or module cursor mutation occurs.
     - Failure modes: A source identity mismatch omits rich source content while retaining the
       persisted bookmark's initials and key.
     */
    func genericBookmarkJSONForStudyPad(
        _ bookmark: GenericBookmark,
        sourceSeed: SwordGenericBookmarkSeed
    ) -> GenericBookmarkData {
        let resolvedSource = bookmark.bookInitials == sourceSeed.source.bookInitials
            && bookmark.key == sourceSeed.source.key
            ? genericSourceContent(for: sourceSeed)
            : nil
        return genericBookmarkJSONForStudyPad(bookmark, resolvedSource: resolvedSource)
    }

    /**
     Serializes one persisted generic bookmark with an already-resolved exact source.

     - Parameters:
       - bookmark: Persisted Android-shaped generic bookmark row.
       - resolvedSource: Exact source metadata and ordered text, or `nil` when unavailable.
     - Returns: Generic bookmark DTO consumed by Vue and StudyPad.
     - Side effects: None.
     - Failure modes: Missing source context emits stable stored identifiers with empty text and no
       fragment; active-reader metadata is never substituted.
     */
    private func genericBookmarkJSONForStudyPad(
        _ bookmark: GenericBookmark,
        resolvedSource: ResolvedGenericBookmarkSourceContent?
    ) -> GenericBookmarkData {
        let id = bookmark.id.uuidString
        let hashCode = Self.normalizedBridgeHashCode(from: id.hashValue)
        let createdAt = bridgeTimestampMilliseconds(bookmark.createdAt)
        let lastUpdated = bridgeTimestampMilliseconds(bookmark.lastUpdatedOn)
        let noteText = bookmark.notes?.notes ?? ""
        let hasNote = !noteText.isEmpty
        let labelPayload = BookmarkLabelSerializationSupport.genericPayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: unlabeledLabelID
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelID(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let source = resolvedSource?.content
        let textProjection = genericBookmarkTextProjection(
            bookmark: bookmark,
            sourceTexts: resolvedSource?.selectedTexts ?? []
        )
        let osisFragment = genericBookmarkOSISFragment(bookmark: bookmark, source: source)

        return GenericBookmarkData(
            id: id,
            type: "generic-bookmark",
            hashCode: hashCode,
            ordinalRange: [bookmark.ordinalStart, bookmark.ordinalEnd],
            offsetRange: bookmark.wholeVerse
                ? nil
                : bookmarkOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset),
            labels: labelPayload.labelIDs,
            bookInitials: bookmark.bookInitials,
            bookName: source?.bookName ?? bookmark.bookInitials,
            bookAbbreviation: source?.bookAbbreviation ?? bookmark.bookInitials,
            createdAt: createdAt,
            text: textProjection.text,
            fullText: textProjection.fullText,
            bookmarkToLabels: labelPayload.relationItems,
            primaryLabelId: primaryLabelId,
            lastUpdatedOn: lastUpdated,
            notes: hasNote ? noteText : nil,
            notesContentType: bookmark.notes?.contentType,
            hasNote: hasNote,
            wholeVerse: bookmark.wholeVerse,
            customIcon: bookmark.customIcon,
            editAction: editActionData(bookmark.editAction),
            key: bookmark.key,
            keyName: source?.keyName ?? bookmark.key,
            highlightedText: textProjection.highlightedText,
            osisFragment: osisFragment
        )
    }

    /**
     Applies Android's generic-bookmark fragment rules to resolved source context.

     Android populates `osisFragment` only for whole-page generic bookmarks. Non-verse keys such as
     dictionary, My Documents, and EPUB pages additionally encode nullable versification and
     ordinal metadata instead of synthetic empty strings or zero ranges.

     - Parameters:
       - bookmark: Persisted generic bookmark whose nullable ordinals define whole-page state.
       - source: Source content resolved strictly from the bookmark's stored provenance.
     - Returns: Android-compatible whole-page fragment, or `nil` for partial/missing content.
     - Side effects: None.
     - Failure modes: Missing source content returns `nil`; unsupported category names are treated
       as non-verse keys so fabricated versification metadata cannot escape.
     */
    private func genericBookmarkOSISFragment(
        bookmark: GenericBookmark,
        source: GenericBookmarkSourceContent?
    ) -> OsisFragment? {
        guard bookmark.ordinalStart == nil || bookmark.ordinalEnd == nil,
              var fragment = source?.osisFragment else {
            return nil
        }
        let isVerseKey = fragment.bookCategory == DocumentCategory.bible.rawValue
            || fragment.bookCategory == DocumentCategory.commentary.rawValue
        if !isVerseKey {
            fragment.v11n = nil
            fragment.ordinalRange = nil
        }
        return fragment
    }

    /**
     Resolves rich generic bookmark context from its persisted source identity.

     My Documents and EPUB providers retain their existing exact resolver. Installed SWORD sources
     reload through the raw-fragment API, which rejects nearest-key substitution and restores
     the same category, OSIS, and local `BVA` text sequence used at creation.

     - Parameter bookmark: Generic bookmark carrying stored `bookInitials` and `key`.
     - Returns: Exact source content and selected anchor texts, or `nil` when unavailable.
     - Side effects: May move the resolved SWORD module cursor while reading its stored key; the
       module serializes cursor access internally.
     - Failure modes: Missing modules, invalid keys, nearest-key normalization, malformed OSIS, and
       persisted ordinals outside the exact fragment fail closed without active-module fallback.
     */
    private func genericSourceContent(
        for bookmark: GenericBookmark
    ) -> ResolvedGenericBookmarkSourceContent? {
        if let source = genericSourceResolver(bookmark.bookInitials, bookmark.key) {
            return ResolvedGenericBookmarkSourceContent(
                content: source,
                selectedTexts: source.plainText.isEmpty ? [] : [source.plainText]
            )
        }
        guard let module = sourceModuleResolver(bookmark.bookInitials),
              let fragment = try? module.rawOSISFragment(forKey: bookmark.key) else {
            return nil
        }

        let selectedTexts: [String]
        if let start = bookmark.ordinalStart, let end = bookmark.ordinalEnd {
            let range = min(start, end)...max(start, end)
            guard fragment.contentOrdinalRange.contains(range.lowerBound),
                  fragment.contentOrdinalRange.contains(range.upperBound) else {
                return nil
            }
            selectedTexts = fragment.text(in: range)
        } else {
            selectedTexts = fragment.text(in: fragment.contentOrdinalRange)
        }
        return resolvedGenericSourceContent(fragment: fragment, selectedTexts: selectedTexts)
    }

    /**
     Projects one immutable generic SWORD seed into the payload source used for its creation event.

     - Parameter seed: Validated generic bookmark seed from the exact rendered fragment.
     - Returns: Exact source metadata and the seed's selected local-anchor texts.
     - Side effects: None.
     - Failure modes: None; seed construction validates source identity, ordinals, and offset pairing before
       constructing the seed.
     */
    private func genericSourceContent(
        for seed: SwordGenericBookmarkSeed
    ) -> ResolvedGenericBookmarkSourceContent {
        resolvedGenericSourceContent(
            fragment: seed.source.osisFragment,
            selectedTexts: seed.text
        )
    }

    /**
     Converts a generic SWORD raw fragment into Android's generic-bookmark source projection.

     - Parameters:
       - fragment: Exact source fragment, including module category and raw OSIS metadata.
       - selectedTexts: Ordered text segments for the bookmark's local ordinal range.
     - Returns: Backend-neutral source metadata paired with exact selected anchor text.
     - Side effects: None.
     - Failure modes: None.
     */
    private func resolvedGenericSourceContent(
        fragment: SwordRawOSISFragment,
        selectedTexts: [String]
    ) -> ResolvedGenericBookmarkSourceContent {
        let allTexts = fragment.text(in: fragment.contentOrdinalRange)
        return ResolvedGenericBookmarkSourceContent(
            content: GenericBookmarkSourceContent(
                bookName: fragment.source.name,
                bookAbbreviation: fragment.source.abbreviation,
                keyName: fragment.keyName,
                plainText: allTexts.joined(),
                osisFragment: bridgeOSISFragment(from: fragment)
            ),
            selectedTexts: selectedTexts
        )
    }

    /**
     Maps an immutable generic SWORD fragment into the shared BibleView OSIS bridge contract.

     - Parameter fragment: Raw SWORD fragment whose source metadata must remain exact.
     - Returns: Bridge fragment preserving module-qualified identity, category, key metadata,
       original XML, features, language, direction, and verse-key ordinals.
     - Side effects: None.
     - Failure modes: None; unknown/add-on categories use the existing generic bridge fallback.
     */
    private func bridgeOSISFragment(from fragment: SwordRawOSISFragment) -> OsisFragment {
        let keyOrdinalRange = fragment.keyOrdinalRange.map { [$0.lowerBound, $0.upperBound] }
        var bridgeFragment = OsisFragment(
            xml: fragment.xml,
            key: fragment.fragmentKey,
            keyName: fragment.keyName,
            v11n: fragment.source.versification,
            bookCategory: bridgeBookCategory(for: fragment.source.category),
            bookInitials: fragment.source.initials,
            bookAbbreviation: fragment.source.abbreviation,
            osisRef: fragment.osisRef,
            isNewTestament: fragment.isNewTestament,
            features: OsisFeatures(
                type: fragment.features["type"],
                keyName: fragment.features["keyName"]
            ),
            hasStrongs: fragment.source.hasStrongs,
            ordinalRange: keyOrdinalRange,
            language: fragment.source.language,
            direction: fragment.source.direction
        )
        bridgeFragment.originalXml = fragment.originalXML
        return bridgeFragment
    }

    /**
     Maps SWORD metadata categories to the JSword `BookCategory.name` values emitted by Android.

     - Parameter category: Installed SWORD module category.
     - Returns: Android bridge category used by `OsisFragment.toHashMap`.
     - Side effects: None.
     - Failure modes: Unsupported add-on metadata is represented as `GENERAL_BOOK`, matching
       Android's generic-document fallback instead of leaking SWORD's display category string.
     */
    private func bridgeBookCategory(for category: ModuleCategory) -> String {
        switch category {
        case .bible:
            return DocumentCategory.bible.rawValue
        case .commentary:
            return DocumentCategory.commentary.rawValue
        case .dictionary, .glossary:
            return DocumentCategory.dictionary.rawValue
        case .generalBook, .dailyDevotion, .addon, .unknown:
            return DocumentCategory.generalBook.rawValue
        case .map:
            return "MAPS"
        }
    }

    /**
     Projects generic source text through Android's whole-page, whole-entry, and offset rules.

     - Parameters:
       - bookmark: Persisted selection flags and UTF-16 offsets.
       - sourceTexts: Ordered text segments for the persisted local ordinal range.
     - Returns: Preview, full text, and `<b>`-highlighted text fields for the Vue DTO.
     - Side effects: none.
     - Failure modes: Missing text returns empty fields. Negative or out-of-range restored offsets
       clamp to the first/last UTF-16 segment so malformed remote rows cannot trap.
     */
    private func genericBookmarkTextProjection(
        bookmark: GenericBookmark,
        sourceTexts: [String]
    ) -> (text: String, fullText: String, highlightedText: String) {
        let projection = genericBookmarkListTextProjection(
            bookmark: bookmark,
            sourceTexts: sourceTexts
        )
        guard !projection.fullText.isEmpty else { return ("", "", "") }
        return (
            projection.selectedText,
            projection.fullText,
            "\(projection.prefix)<b>\(projection.selectedText)</b>\(projection.suffix)"
        )
    }

    /**
     Applies Android's special whole-page preview rule before the shared offset projection.

     - Parameters:
       - bookmark: Persisted generic bookmark selection metadata.
       - sourceTexts: Exact ordered source-anchor text.
     - Returns: Bookmark-list text segments, or `empty` when source text is unavailable.
     - Side effects: none.
     - Failure modes: Invalid offsets are clamped by the shared projection helper.
     */
    private func genericBookmarkListTextProjection(
        bookmark: GenericBookmark,
        sourceTexts: [String]
    ) -> BookmarkListTextProjection {
        guard let firstText = sourceTexts.first else { return .empty }
        if bookmark.ordinalStart == nil || bookmark.ordinalEnd == nil {
            let first = firstText as NSString
            let preview = first.substring(with: NSRange(location: 0, length: min(200, first.length)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BookmarkListTextProjection(
                prefix: "",
                selectedText: preview,
                suffix: "",
                fullText: preview
            )
        }
        return Self.bookmarkTextProjection(
            sourceTexts: sourceTexts,
            startOffset: bookmark.startOffset,
            endOffset: bookmark.endOffset,
            wholeVerse: bookmark.wholeVerse
        ) ?? .empty
    }

    /**
     Slices ordered source text exactly like Android `computeBookmarkTexts`.

     Persisted offsets come from WebView selections and therefore use UTF-16 code units. `NSString`
     preserves that indexing contract and lets malformed synced offsets clamp without trapping.

     - Parameters:
       - sourceTexts: Ordered verse or anchor text for the bookmark range.
       - startOffset: UTF-16 offset into the first source segment.
       - endOffset: UTF-16 offset into the final source segment.
       - wholeVerse: Whether the complete first/final segments are selected.
     - Returns: Structured selection text, or `nil` when no source segments exist.
     - Side effects: none.
     - Failure modes: Negative and out-of-range offsets are clamped.
     */
    private static func bookmarkTextProjection(
        sourceTexts: [String],
        startOffset: Int?,
        endOffset: Int?,
        wholeVerse: Bool
    ) -> BookmarkListTextProjection? {
        guard let firstText = sourceTexts.first else { return nil }
        let first = firstText as NSString
        let clampedStart = wholeVerse
            ? 0
            : max(0, min(startOffset ?? 0, first.length))
        let prefix = first.substring(with: NSRange(location: 0, length: clampedStart))

        let selected: String
        let suffix: String
        if sourceTexts.count == 1 {
            let requestedEnd = wholeVerse ? first.length : (endOffset ?? first.length)
            let clampedEnd = max(clampedStart, min(max(0, requestedEnd), first.length))
            selected = first.substring(
                with: NSRange(location: clampedStart, length: clampedEnd - clampedStart)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            suffix = first.substring(
                with: NSRange(location: clampedEnd, length: first.length - clampedEnd)
            )
        } else {
            let firstSelection = first.substring(
                with: NSRange(location: clampedStart, length: first.length - clampedStart)
            )
            let last = (sourceTexts.last ?? "") as NSString
            let requestedEnd = wholeVerse ? last.length : (endOffset ?? last.length)
            let clampedEnd = max(0, min(requestedEnd, last.length))
            let lastSelection = last.substring(with: NSRange(location: 0, length: clampedEnd))
            suffix = last.substring(
                with: NSRange(location: clampedEnd, length: last.length - clampedEnd)
            )
            let middle = sourceTexts.count > 2
                ? sourceTexts[1..<(sourceTexts.count - 1)].joined(separator: " ")
                : ""
            selected = "\(firstSelection)\(middle)\(lastSelection)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return BookmarkListTextProjection(
            prefix: prefix,
            selectedText: selected,
            suffix: suffix,
            fullText: "\(prefix)\(selected)\(suffix)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /**
     Builds a typed StudyPad text entry payload for Vue.js.

     - Parameter entry: StudyPad text entry stored under a label.
     - Returns: The `journal` item payload expected by the reader client.
     - Side effects: None.
     - Failure modes: missing label relationships produce an empty label identifier, preserving the
       previous bridge payload shape.
     */
    func studyPadEntryJSON(_ entry: StudyPadTextEntry) -> StudyPadTextItemData {
        let id = entry.id.uuidString
        let hashCode = Self.normalizedBridgeHashCode(from: id.hashValue)
        let labelId = BookmarkLabelSerializationSupport.liveLabelIDString(for: entry.label) ?? ""
        let text = entry.textEntry?.text ?? ""
        return StudyPadTextItemData(
            id: id,
            type: "journal",
            hashCode: hashCode,
            labelId: labelId,
            text: text,
            contentType: entry.contentType,
            orderNumber: entry.orderNumber,
            indentLevel: entry.indentLevel
        )
    }

    /**
     Builds a typed Bible bookmark-to-label payload for Vue.js.

     - Parameter btl: Persisted Bible bookmark-to-label relationship.
     - Returns: A relationship DTO, or `nil` when the label has been deleted.
     - Side effects: None.
     - Failure modes: missing labels are skipped so Vue never receives invalid label identifiers.
     */
    func bibleBookmarkToLabelJSON(_ btl: BibleBookmarkToLabel) -> BookmarkToLabelData? {
        let bmId = btl.bookmark?.id.uuidString ?? ""
        guard let lblId = BookmarkLabelSerializationSupport.liveLabelIDString(for: btl.label) else {
            return nil
        }
        return BookmarkToLabelData(
            bookmarkId: bmId,
            labelId: lblId,
            orderNumber: btl.orderNumber,
            indentLevel: btl.indentLevel,
            expandContent: btl.expandContent,
            type: "BibleBookmarkToLabel"
        )
    }

    /**
     Builds a typed generic bookmark-to-label payload for Vue.js.

     - Parameter gbtl: Persisted generic bookmark-to-label relationship.
     - Returns: A relationship DTO, or `nil` when the label has been deleted.
     - Side effects: None.
     - Failure modes: missing labels are skipped so Vue never receives invalid label identifiers.
     */
    func genericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel) -> BookmarkToLabelData? {
        let bmId = gbtl.bookmark?.id.uuidString ?? ""
        guard let lblId = BookmarkLabelSerializationSupport.liveLabelIDString(for: gbtl.label) else {
            return nil
        }
        return BookmarkToLabelData(
            bookmarkId: bmId,
            labelId: lblId,
            orderNumber: gbtl.orderNumber,
            indentLevel: gbtl.indentLevel,
            expandContent: gbtl.expandContent,
            type: "GenericBookmarkToLabel"
        )
    }

    /**
     Builds a typed label payload for bridge documents and label update events.

     - Parameter label: Persisted label model to project.
     - Returns: A label DTO, or `nil` if the label has no live identifier.
     - Side effects: None.
     - Failure modes: missing label identifiers are skipped rather than emitting malformed bridge
       state.
     */
    func labelData(_ label: Label) -> LabelData? {
        guard let labelID = BookmarkLabelSerializationSupport.liveLabelIDString(for: label) else {
            return nil
        }
        return LabelData(
            id: labelID,
            name: label.name,
            style: BookmarkStyleData(
                color: label.color,
                isSpeak: label.name == BibleCore.Label.speakLabelName,
                isParagraphBreak: label.name == BibleCore.Label.paragraphBreakLabelName,
                underline: label.underlineStyle,
                underlineWholeVerse: label.underlineStyleWholeVerse,
                markerStyle: label.markerStyle,
                markerStyleWholeVerse: label.markerStyleWholeVerse,
                hideStyle: label.hideStyle,
                hideStyleWholeVerse: label.hideStyleWholeVerse,
                customIcon: label.customIcon
            ),
            isRealLabel: label.isRealLabel
        )
    }

    /**
     Builds a Bible bookmark DTO with caller-selected edit-action metadata.

     - Parameters:
       - bookmark: Bible bookmark model to project.
       - editAction: Edit-action DTO value required by the target bridge context.
       - ordinalProjection: Target document ordinal domain: active module for normal Bible
         documents, KJVA for Android's My Notes fake document.
     - Returns: A typed Bible bookmark payload.
     - Side effects: reads verse text from the active SWORD module when available.
     - Failure modes: missing label relationships are filtered through shared serialization
       support.
     */
    private func bibleBookmarkJSON(
        _ bookmark: BibleBookmark,
        editAction: EditActionData?,
        ordinalProjection: BibleBookmarkOrdinalProjection = .activeModule
    ) -> BibleBookmarkData {
        let id = bookmark.id.uuidString
        let hashCode = Self.normalizedBridgeHashCode(from: id.hashValue)
        let createdAt = bridgeTimestampMilliseconds(bookmark.createdAt)
        let lastUpdated = bridgeTimestampMilliseconds(bookmark.lastUpdatedOn)
        let noteText = bookmark.notes?.notes ?? ""
        let hasNote = !noteText.isEmpty
        let labelPayload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: unlabeledLabelID
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelID(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let bookmarkBook = bookmark.book ?? currentBook
        let rangeProjection = bibleBookmarkRangeProjection(
            bookName: bookmarkBook,
            sourceStartOrdinal: bookmark.ordinalStart,
            sourceEndOrdinal: bookmark.ordinalEnd,
            kjvStartOrdinal: bookmark.kjvOrdinalStart,
            kjvEndOrdinal: bookmark.kjvOrdinalEnd,
            ordinalProjection: ordinalProjection
        )
        let textRangeProjection = ordinalProjection == .activeModule ? rangeProjection : bibleBookmarkRangeProjection(
            bookName: bookmarkBook,
            sourceStartOrdinal: bookmark.ordinalStart,
            sourceEndOrdinal: bookmark.ordinalEnd,
            kjvStartOrdinal: bookmark.kjvOrdinalStart,
            kjvEndOrdinal: bookmark.kjvOrdinalEnd,
            ordinalProjection: .activeModule
        )
        let fullText = loadVerseText(for: textRangeProjection)
        let sourceModuleMetadata = sourceModuleMetadata(for: bookmark)
        let hasSourceModule = !sourceModuleMetadata.initials.isEmpty
        let effectiveWholeVerse = bookmark.wholeVerse || !hasSourceModule
        let effectiveSourceEndOrdinal = bookmark.ordinalEnd > bookmark.ordinalStart
            ? bookmark.ordinalEnd
            : bookmark.ordinalStart

        return BibleBookmarkData(
            id: id,
            type: "bookmark",
            hashCode: hashCode,
            ordinalRange: [rangeProjection.start.ordinal, rangeProjection.end.ordinal],
            offsetRange: effectiveWholeVerse
                ? nil
                : bookmarkOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset),
            labels: labelPayload.labelIDs,
            bookInitials: sourceModuleMetadata.initials,
            bookName: sourceModuleMetadata.name,
            bookAbbreviation: sourceModuleMetadata.abbreviation,
            createdAt: createdAt,
            text: fullText,
            fullText: fullText,
            bookmarkToLabels: labelPayload.relationItems,
            primaryLabelId: primaryLabelId,
            lastUpdatedOn: lastUpdated,
            notes: hasNote ? noteText : nil,
            notesContentType: bookmark.notes?.contentType,
            hasNote: hasNote,
            wholeVerse: effectiveWholeVerse,
            customIcon: bookmark.customIcon,
            editAction: editAction,
            osisRef: rangeProjection.osisRef,
            originalOrdinalRange: [bookmark.ordinalStart, effectiveSourceEndOrdinal],
            verseRange: rangeProjection.verseRange,
            verseRangeOnlyNumber: rangeProjection.verseRangeOnlyNumber,
            verseRangeAbbreviated: rangeProjection.verseRangeAbbreviated,
            v11n: hasSourceModule ? bookmark.v11n : JSwordKJVAVersification.name,
            osisFragment: nil
        )
    }

    /**
     Resolves a bookmark's stored ordinals into the bridge range projection used by Android's
     `ClientBibleBookmark` fields.

     - Parameters:
       - bookName: Stored or current start book name used only by legacy fallback paths.
       - sourceStartOrdinal: Stored start ordinal in the bookmark source versification.
       - sourceEndOrdinal: Stored end ordinal in the bookmark source versification.
       - kjvStartOrdinal: Stored start ordinal in Android's KJVA bookmark domain.
       - kjvEndOrdinal: Stored end ordinal in Android's KJVA bookmark domain.
       - ordinalProjection: Target document ordinal domain for emitted `ordinalRange`.
     - Returns: A normalized range projection. Invalid or reversed end ordinals collapse to the
       start verse, matching existing single-verse normalization.
     - Side effects: May query the active SWORD module for KJVA-to-rendered ordinal projection.
     - Failure modes: falls back to the source ordinal and no-module compatibility projection when
       a malformed legacy row cannot be resolved through KJVA.
     */
    private func bibleBookmarkRangeProjection(
        bookName: String,
        sourceStartOrdinal: Int,
        sourceEndOrdinal: Int,
        kjvStartOrdinal: Int,
        kjvEndOrdinal: Int,
        ordinalProjection: BibleBookmarkOrdinalProjection
    ) -> BookmarkBridgeVerseRangeProjection {
        let startReference = renderedReference(
            kjvOrdinal: kjvStartOrdinal,
            sourceOrdinal: sourceStartOrdinal,
            bookName: bookName,
            ordinalProjection: ordinalProjection
        )
        let effectiveSourceEndOrdinal = sourceEndOrdinal > sourceStartOrdinal
            ? sourceEndOrdinal
            : sourceStartOrdinal
        let effectiveKJVEndOrdinal = kjvEndOrdinal > kjvStartOrdinal
            ? kjvEndOrdinal
            : kjvStartOrdinal
        let endReference = renderedReference(
            kjvOrdinal: effectiveKJVEndOrdinal,
            sourceOrdinal: effectiveSourceEndOrdinal,
            bookName: bookName,
            ordinalProjection: ordinalProjection
        )

        return BookmarkBridgeVerseRangeProjection(
            startBookName: bridgeBookName(for: startReference, fallback: bookName),
            startBookAbbreviation: bridgeBookAbbreviation(for: startReference),
            start: startReference,
            endBookName: bridgeBookName(for: endReference, fallback: bookName),
            endBookAbbreviation: bridgeBookAbbreviation(for: endReference),
            end: endReference
        )
    }

    /**
     Resolves a stored KJVA bookmark ordinal into the target document's rendered ordinal space.

     Android backups identify Bible bookmarks by KJVA ordinals even when the `book` column stores
     module initials or NULL. Normal Bible documents reverse-map the stored KJVA reference into the
     active module's versification (Android's `verseRange.toV11n(activeV11n)`) and use that module's
     rendered ordinal for Vue highlight matching, while Android's My Notes fake document uses KJVA
     ordinals directly.

     - Parameters:
       - kjvOrdinal: Persisted Android-compatible KJVA ordinal.
       - sourceOrdinal: Persisted source ordinal used only by legacy fallback paths.
       - bookName: Stored or current book name used only by legacy fallback paths.
       - ordinalProjection: Target document ordinal domain for emitted ordinals.
     - Returns: Verse reference in the requested document domain. Android's ordinal `0` sentinel is
       used when a public conversion result is not addressable by the active module.
     - Side effects: May temporarily move the active SWORD module cursor through
       `verseOrdinal(osisBookId:chapter:verse:)`.
     - Failure modes: Malformed KJVA ordinals retain best-effort display coordinates with ordinal
       `0`; source ordinals are never reinterpreted as KJVA or active-module ordinals.
     */
    private func renderedReference(
        kjvOrdinal: Int,
        sourceOrdinal: Int,
        bookName: String,
        ordinalProjection: BibleBookmarkOrdinalProjection
    ) -> VerseKeyReference {
        if let kjvaReference = JSwordKJVAVersification.referenceIncludingIntroductions(
            ordinal: kjvOrdinal
        ) {
            switch ordinalProjection {
            case .activeModule:
                guard let activeModule else {
                    return VerseKeyReference(
                        osisBookId: kjvaReference.osisId,
                        chapter: kjvaReference.chapter,
                        verse: kjvaReference.verse,
                        ordinal: kjvaReference.ordinal
                    )
                }
                guard let projection = VersificationMapper.moduleProjection(
                    forKJVAOrdinal: kjvOrdinal,
                    targetModule: activeModule
                ) else {
                    return VerseKeyReference(
                        osisBookId: kjvaReference.osisId,
                        chapter: kjvaReference.chapter,
                        verse: kjvaReference.verse,
                        ordinal: 0
                    )
                }
                return VerseKeyReference(
                    osisBookId: projection.reference.osisBookId,
                    chapter: projection.reference.chapter,
                    verse: projection.reference.verse,
                    ordinal: projection.ordinal
                )
            case .kjva:
                return VerseKeyReference(
                    osisBookId: kjvaReference.osisId,
                    chapter: kjvaReference.chapter,
                    verse: kjvaReference.verse,
                    ordinal: kjvaReference.ordinal
                )
            }
        }
        let fallback = verseReference(book: bookName, ordinal: sourceOrdinal)
            ?? activeModule?.verseReference(ordinal: sourceOrdinal)
            ?? fallbackVerseReference(bookName: bookName, ordinal: sourceOrdinal)
        return VerseKeyReference(
            osisBookId: fallback.osisBookId,
            chapter: fallback.chapter,
            verse: fallback.verse,
            ordinal: 0
        )
    }

    /**
     Projects source module metadata for Android's bookmark modal contract.

     Android's `ClientBibleBookmark` emits metadata from `bookmark.book`, the source passage book
     stored with the bookmark. iOS keeps display book names in `BibleBookmark.book`, so the bridge
     must read the separate source-module initials field and only use the active module description
     when it is actually the same module.

     - Parameter bookmark: Bible bookmark being serialized.
     - Returns: Source initials/name/abbreviation tuple, or empty strings when Android would have
       had a NULL source book.
     - Side effects: none.
     - Failure modes: Missing active-module description falls back to initials.
     */
    private func sourceModuleMetadata(for bookmark: BibleBookmark) -> (initials: String, name: String, abbreviation: String) {
        let initials = bookmark.bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initials.isEmpty else {
            return ("", "", "")
        }
        guard let sourceModule = sourceModuleResolver(initials) else {
            return (initials, initials, initials)
        }
        let description = sourceModule.info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            initials,
            description.isEmpty ? initials : description,
            sourceModule.info.name.isEmpty ? initials : sourceModule.info.name
        )
    }

    /**
     Resolves a persisted ordinal back to a verse reference for one book.

     - Parameters:
       - book: User-facing book name used to derive the OSIS identifier.
       - ordinal: Persisted verse ordinal.
     - Returns: A verse reference in the requested book, or `nil` for invalid ordinals.
     - Side effects: May temporarily move the active SWORD module cursor.
     - Failure modes: falls back to the historical placeholder calculation only when no active
       module is available.
     */
    private func verseReference(book: String, ordinal: Int) -> VerseKeyReference? {
        bookCatalog.verseReference(book: book, ordinal: ordinal)
    }

    /**
     Creates a no-module compatibility reference for malformed or unresolved bookmark ordinals.

     - Parameters:
       - bookName: Display name used to derive a fallback OSIS book identifier.
       - ordinal: Persisted ordinal to normalize.
     - Returns: A positive, synthetic verse reference.
     - Side effects: None.
     - Failure modes: non-positive ordinals are clamped to `1`.
     */
    private func fallbackVerseReference(bookName: String, ordinal: Int) -> VerseKeyReference {
        let safeOrdinal = max(1, ordinal)
        let chapter = max(1, ((safeOrdinal - 1) / 40) + 1)
        let verse = max(1, safeOrdinal - ((chapter - 1) * 40))
        return VerseKeyReference(
            osisBookId: osisBookId(for: bookName),
            chapter: chapter,
            verse: verse,
            ordinal: safeOrdinal
        )
    }

    /**
     Looks up an OSIS book identifier in the active book list.

     - Parameter bookName: Display book name from reader state or persisted bookmark data.
     - Returns: Active-module OSIS identifier, static no-module fallback identifier, or an empty
       string when an active module has no matching book.
     - Side effects: None.
     - Failure modes: returns an empty string under the same active-module-mismatch conditions as
       the previous controller implementation.
     */
    private func osisBookId(for bookName: String) -> String {
        bookCatalog.osisBookId(for: bookName)
    }

    /**
     Resolves the display book name emitted in bookmark range text.

     - Parameters:
       - reference: Resolved verse reference.
       - fallback: Book name to preserve when static lookup fails.
     - Returns: Static display name or caller fallback.
     - Side effects: None.
     - Failure modes: None.
     */
    private func bridgeBookName(for reference: VerseKeyReference, fallback: String) -> String {
        BibleReaderController.bookName(forOsisId: reference.osisBookId)
            ?? JSwordKJVAVersification.longBookName(osisId: reference.osisBookId)
            ?? fallback
    }

    /**
     Resolves the abbreviated book name emitted in compact bookmark range text.

     - Parameter reference: Resolved verse reference.
     - Returns: Static abbreviation, or the OSIS book identifier when no abbreviation is known.
     - Side effects: None.
     - Failure modes: None.
     */
    private func bridgeBookAbbreviation(for reference: VerseKeyReference) -> String {
        BibleReaderController.defaultBooks.first(where: { $0.osisId == reference.osisBookId })?.abbreviation
            ?? reference.osisBookId
    }

    /**
     Loads plain text for an ordinal-backed verse range from the active SWORD module.

     Android's bookmark DTO uses a JSword `VerseRange`, so text extraction can span chapter
     boundaries. Iterating the resolved SWORD ordinals keeps iOS aligned with that behavior instead
     of assuming the start chapter applies to every verse in the bookmark.

     - Parameter range: Normalized bookmark verse range projection.
     - Returns: Space-joined plain text for all resolved verses.
     - Side effects: Temporarily moves the active SWORD module cursor.
     - Failure modes: returns an empty string when no active module is available or no verses
       resolve.
     */
    private func loadVerseText(for range: BookmarkBridgeVerseRangeProjection) -> String {
        loadVerseTexts(for: range).joined(separator: " ")
    }

    /**
     Loads each canonical verse as a separate text segment so bookmark offsets retain Android's
     first-verse/last-verse semantics.

     - Parameter range: Active-module verse range resolved for bridge and Bookmark-list rendering.
     - Returns: Non-empty canonical verse strings in ordinal order.
     - Side effects: Moves the active SWORD module cursor while reading each verse.
     - Failure modes: Missing modules and unresolved verse ordinals return no segment.
     */
    private func loadVerseTexts(for range: BookmarkBridgeVerseRangeProjection) -> [String] {
        guard let module = activeModule else { return [] }
        var parts: [String] = []

        let lowerOrdinal = min(range.start.ordinal, range.end.ordinal)
        let upperOrdinal = max(range.start.ordinal, range.end.ordinal)
        for ordinal in lowerOrdinal...upperOrdinal {
            guard let reference = module.verseReference(ordinal: ordinal) else {
                continue
            }
            let key = "\(reference.osisBookId) \(reference.chapter):\(reference.verse)"
            module.setKey(key)
            let raw = module.rawEntry()
            let plain = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                parts.append(plain)
            }
        }
        return parts
    }

    /**
     Converts a native `Date` into the integer millisecond timestamp expected by the web bridge.

     - Parameter date: Native timestamp to serialize into the bridge payload.
     - Returns: Unix epoch milliseconds, truncating sub-millisecond precision to match the previous
       manual JSON builders.
     - Side effects: None.
     - Failure modes: None for valid `Date` values.
     */
    private func bridgeTimestampMilliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    /**
     Projects optional bookmark text offsets into the array form expected by Vue.js.

     - Parameters:
       - startOffset: Optional inclusive start offset inside the verse text.
       - endOffset: Optional inclusive end offset inside the verse text.
     - Returns: `nil` when no start offset exists, otherwise a two-element array whose end may be
       `nil` and therefore encodes as JSON `null`.
     - Side effects: None.
     - Failure modes: None.
     */
    private func bookmarkOffsetRange(startOffset: Int?, endOffset: Int?) -> [Int?]? {
        guard let startOffset else { return nil }
        return [startOffset, endOffset]
    }

    /**
     Projects a persisted bookmark edit action into the bridge DTO.

     - Parameter editAction: Optional persisted edit-action model.
     - Returns: Bridge edit-action DTO preserving nullable mode/content fields.
     - Side effects: None.
     - Failure modes: None.
     */
    private func editActionData(_ editAction: EditAction?) -> EditActionData {
        EditActionData(mode: editAction?.mode?.rawValue, content: editAction?.content)
    }
}

/**
 Ordinal-backed Bible bookmark range projected into the bridge fields used by Vue.js.

 Android serializes bookmark ranges from a JSword `VerseRange`; this projection is the iOS
 equivalent. It keeps `osisRef`, display names, abbreviated names, and number-only labels derived
 from one resolved start/end pair instead of repeating range formatting at each bridge call site.
 */
private struct BookmarkBridgeVerseRangeProjection {
    /// Display name for the starting book.
    let startBookName: String
    /// Compact display name for the starting book.
    let startBookAbbreviation: String
    /// Resolved starting verse reference.
    let start: VerseKeyReference
    /// Display name for the ending book.
    let endBookName: String
    /// Compact display name for the ending book.
    let endBookAbbreviation: String
    /// Resolved ending verse reference.
    let end: VerseKeyReference

    /// Whether the projection represents a single verse rather than a span.
    private var isSingleVerse: Bool {
        start.osisBookId == end.osisBookId
            && start.chapter == end.chapter
            && start.verse == end.verse
    }

    /// OSIS reference string used by the web client.
    var osisRef: String {
        let startRef = "\(start.osisBookId).\(start.chapter).\(start.verse)"
        guard !isSingleVerse else { return startRef }
        return "\(startRef)-\(end.osisBookId).\(end.chapter).\(end.verse)"
    }

    /// Full display verse range.
    var verseRange: String {
        formattedRange(startBook: startBookName, endBook: endBookName)
    }

    /// Number-only range used by compact bookmark UI.
    var verseRangeOnlyNumber: String {
        isSingleVerse ? "\(start.verse)" : "\(start.verse)-\(end.verse)"
    }

    /// Abbreviated display verse range.
    var verseRangeAbbreviated: String {
        formattedRange(startBook: startBookAbbreviation, endBook: endBookAbbreviation)
    }

    /**
     Formats this projection with caller-selected book display names.

     - Parameters:
       - startBook: Display name to use for the start book.
       - endBook: Display name to use for the end book when the range crosses books.
     - Returns: Human-readable verse range.
     - Side effects: None.
     - Failure modes: None.
     */
    private func formattedRange(startBook: String, endBook: String) -> String {
        if isSingleVerse {
            return "\(startBook) \(start.chapter):\(start.verse)"
        }
        if start.osisBookId == end.osisBookId {
            if start.chapter == end.chapter {
                return "\(startBook) \(start.chapter):\(start.verse)-\(end.verse)"
            }
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.chapter):\(end.verse)"
        }
        return "\(startBook) \(start.chapter):\(start.verse)-\(endBook) \(end.chapter):\(end.verse)"
    }
}
