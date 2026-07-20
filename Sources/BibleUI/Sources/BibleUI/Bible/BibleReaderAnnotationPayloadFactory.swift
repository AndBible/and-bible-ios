import Foundation
import BibleCore
import BibleView
import SwordKit

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
    /// Active-module-aware catalog used for OSIS lookup and ordinal projection.
    private let bookCatalog: BibleReaderBookCatalog
    /// Synthetic unlabeled label identifier required by the web client.
    private let unlabeledLabelID: String
    /// Active module versification, read once so per-bookmark projection avoids repeated SWORD reads.
    private let activeVersification: String
    /**
     Whether the active module renders KJVA-compatible numbering (KJV-family), in which case the
     reverse KJVA->active mapping is identity and can be skipped.
     */
    private let activeVersificationIsKJVACompatible: Bool

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
       - bookCatalog: Active-module-aware catalog boundary for OSIS and ordinal projection.
       - unlabeledLabelID: Stable identifier for the synthetic unlabeled label.
     - Side effects: None during initialization.
     - Failure modes: None; per-payload methods handle missing model relationships.
     */
    init(
        currentBook: String,
        activeModuleName: String,
        activeModule: SwordModule?,
        bookCatalog: BibleReaderBookCatalog,
        unlabeledLabelID: String
    ) {
        self.currentBook = currentBook
        self.activeModuleName = activeModuleName
        self.activeModule = activeModule
        self.bookCatalog = bookCatalog
        self.unlabeledLabelID = unlabeledLabelID
        let versification = activeModule?.configEntry("Versification")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.activeVersification = versification
        let normalized = versification.uppercased()
        self.activeVersificationIsKJVACompatible = versification.isEmpty || normalized == "KJV" || normalized == "KJVA"
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

        return GenericBookmarkData(
            id: id,
            type: "generic-bookmark",
            hashCode: hashCode,
            ordinalRange: [bookmark.ordinalStart, bookmark.ordinalEnd],
            offsetRange: bookmarkOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset),
            labels: labelPayload.labelIDs,
            bookInitials: bookmark.bookInitials,
            bookName: bookmark.bookInitials,
            bookAbbreviation: "",
            createdAt: createdAt,
            text: "",
            fullText: "",
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
            keyName: bookmark.key,
            highlightedText: ""
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
     - Returns: Verse reference with an active-module ordinal when possible, otherwise a KJVA or
       compatibility fallback reference.
     - Side effects: May temporarily move the active SWORD module cursor through
       `verseOrdinal(osisBookId:chapter:verse:)`.
     - Failure modes: Malformed KJVA ordinals fall back to legacy source-ordinal resolution.
     */
    private func renderedReference(
        kjvOrdinal: Int,
        sourceOrdinal: Int,
        bookName: String,
        ordinalProjection: BibleBookmarkOrdinalProjection
    ) -> VerseKeyReference {
        if let kjvaReference = JSwordKJVAVersification.verseReference(ordinal: kjvOrdinal) {
            switch ordinalProjection {
            case .activeModule:
                // KJV-family modules render KJVA numbering identically, so skip the reverse map and
                // take the active module's ordinal for the KJVA coordinates directly (no SWORD
                // mapping per bookmark).
                if activeVersificationIsKJVACompatible {
                    let renderedOrdinal = activeModule?.verseOrdinal(
                        osisBookId: kjvaReference.osisId,
                        chapter: kjvaReference.chapter,
                        verse: kjvaReference.verse
                    ) ?? kjvaReference.ordinal
                    return VerseKeyReference(
                        osisBookId: kjvaReference.osisId,
                        chapter: kjvaReference.chapter,
                        verse: kjvaReference.verse,
                        ordinal: renderedOrdinal
                    )
                }
                // Divergent canon: reverse-map the stored KJVA reference into the active module's
                // versification (Android's verseRange.toV11n(activeV11n)), then take that module's
                // rendered ordinal, so it lands on the true active verse (e.g. KJVA Ps 10:1 ->
                // Vulgate Ps 9:22) instead of the identically-numbered KJVA verse.
                if let activeModule,
                   let mapped = SwordVersification.mapVerseFromKJVA(
                       osisBookId: kjvaReference.osisId,
                       chapter: kjvaReference.chapter,
                       verse: kjvaReference.verse,
                       targetVersification: activeVersification
                   ),
                   let activeOrdinal = activeModule.verseOrdinal(
                       osisBookId: mapped.osisBookId,
                       chapter: mapped.chapter,
                       verse: mapped.verse
                   ) {
                    return VerseKeyReference(
                        osisBookId: mapped.osisBookId,
                        chapter: mapped.chapter,
                        verse: mapped.verse,
                        ordinal: activeOrdinal
                    )
                }
                // No active module, or a reference the active module cannot render (e.g. a
                // superscription): fall back to the KJVA coordinates and ordinal.
                return VerseKeyReference(
                    osisBookId: kjvaReference.osisId,
                    chapter: kjvaReference.chapter,
                    verse: kjvaReference.verse,
                    ordinal: kjvaReference.ordinal
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
        return verseReference(book: bookName, ordinal: sourceOrdinal)
            ?? activeModule?.verseReference(ordinal: sourceOrdinal)
            ?? fallbackVerseReference(bookName: bookName, ordinal: sourceOrdinal)
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
        let activeDescription = activeModuleName == initials
            ? activeModule?.info.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : ""
        let name = activeDescription.isEmpty ? initials : activeDescription
        return (initials, name, initials)
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
        guard let module = activeModule else { return "" }
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
        return parts.joined(separator: " ")
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
