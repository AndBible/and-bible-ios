import BibleCore
import SwordKit

/** One exact coordinate in Android's fake `MyNote` KJVA document. */
struct BibleReaderMyNotesKJVAPosition: Sendable, Equatable {
    let osisBookID: String
    let chapter: Int
    let verse: Int
    let ordinal: Int

    var key: String { "\(osisBookID).\(chapter).\(verse)" }
}

/** Defines whether My Notes expands a retained source chapter or a KJVA-normalized selected key. */
enum BibleReaderMyNotesRenderIntent: Sendable, Equatable {
    /// Direct pseudo-document and synchronized-current-Bible routes retain source chapter shape.
    case sourceChapter(MyNotesSourceChapter, sourceVerse: Int?)
    /// `MyNote.setKey` routes expand the chapter owning the already-normalized KJVA selection.
    case selectedKJVAChapter
}

/**
 Owns one synchronously accepted My Notes position independently from asynchronous rendering.

 `sharedPosition` is the destination Bible coordinate used for traversal and toolbar state.
 `kjvaPosition` is the authoritative fake-document key used for history, rendered scrolling, and
 synchronized-window publication. Keeping both forward projections prevents a lossy reverse
 conversion through the destination Bible versification.
 */
struct BibleReaderMyNotesIntent: Sendable, Equatable {
    let acceptanceID: UInt64
    let sharedPosition: MyNotesSourceChapter
    let sharedVerse: Int
    let kjvaPosition: BibleReaderMyNotesKJVAPosition
    let render: BibleReaderMyNotesRenderIntent

    /** Refreshes the visible anchor while retaining the accepted render-span ingress. */
    func refreshingAnchor(
        sharedPosition: MyNotesSourceChapter,
        sharedVerse: Int,
        kjvaPosition: BibleReaderMyNotesKJVAPosition
    ) -> Self {
        Self(
            acceptanceID: acceptanceID,
            sharedPosition: sharedPosition,
            sharedVerse: sharedVerse,
            kjvaPosition: kjvaPosition,
            render: render
        )
    }
}

/** Performs bounded single-coordinate admission before My Notes mutates reader state. */
enum BibleReaderMyNotesIntentAdmission {
    /** Admits a `MyNote.setKey` route by normalizing exactly one source coordinate through KJVA. */
    static func selectedVerse(
        acceptanceID: UInt64,
        sourceVersification: String,
        osisBookID: String,
        chapter: Int,
        verse: Int,
        destinationVersification: String
    ) -> BibleReaderMyNotesIntent? {
        guard chapter >= 0, verse >= 0, chapter > 0 || verse == 0 else { return nil }
        // Android normalizes a book introduction through the selected-key route to the first
        // chapter verse; chapter introductions remain exact verse-zero selections.
        let mappedChapter = chapter == 0 ? 1 : chapter
        let mappedVerse = chapter == 0 ? 1 : verse
        guard
              let kjva = VersificationMapper.convertStrictly(
                osisBookId: osisBookID,
                chapter: mappedChapter,
                verse: mappedVerse,
                from: sourceVersification,
                to: JSwordKJVAVersification.name
              )?.reference,
              let kjvaPosition = kjvaPosition(kjva) else { return nil }
        let destination = VersificationMapper.convertStrictly(
                osisBookId: kjva.osisBookId,
                chapter: kjva.chapter,
                verse: kjva.verse,
                from: JSwordKJVAVersification.name,
                to: destinationVersification
              )?.reference
        let sharedVersification = destination == nil
            ? JSwordKJVAVersification.name
            : destinationVersification
        let shared = destination ?? kjva
        return BibleReaderMyNotesIntent(
            acceptanceID: acceptanceID,
            sharedPosition: .init(
                versification: sharedVersification,
                osisBookId: shared.osisBookId,
                chapter: shared.chapter
            ),
            sharedVerse: shared.verse,
            kjvaPosition: kjvaPosition,
            render: .selectedKJVAChapter
        )
    }

    /**
     Admits retained-source-chapter semantics using one anchor conversion.

     Full chapter endpoint mapping and bookmark extraction remain worker work. This boundary only
     validates the normalized source identity and produces the shared/KJVA anchor needed to accept
     the action synchronously.
     */
    static func sourceChapter(
        acceptanceID: UInt64,
        sourceVersification: String,
        osisBookID: String,
        chapter: Int,
        sourceVerse: Int?,
        destinationVersification: String
    ) -> BibleReaderMyNotesIntent? {
        guard let normalized = JSwordVersificationRegistry.normalizedName(sourceVersification),
              !osisBookID.isEmpty,
              chapter >= 0 else { return nil }
        let anchor = sourceVerse ?? (chapter == 0 ? 0 : 1)
        guard anchor >= 0, chapter > 0 || anchor == 0,
              let kjva = VersificationMapper.convertStrictly(
                osisBookId: osisBookID,
                chapter: chapter,
                verse: anchor,
                from: normalized,
                to: JSwordKJVAVersification.name
              )?.reference,
              let kjvaPosition = kjvaPosition(kjva) else { return nil }
        let destination = VersificationMapper.convertStrictly(
                osisBookId: osisBookID,
                chapter: chapter,
                verse: anchor,
                from: normalized,
                to: destinationVersification
              )?.reference
        let sharedVersification = destination == nil ? normalized : destinationVersification
        let shared = destination ?? .init(
            osisBookId: osisBookID,
            chapter: chapter,
            verse: anchor
        )
        return BibleReaderMyNotesIntent(
            acceptanceID: acceptanceID,
            sharedPosition: .init(
                versification: sharedVersification,
                osisBookId: shared.osisBookId,
                chapter: shared.chapter
            ),
            sharedVerse: shared.verse,
            kjvaPosition: kjvaPosition,
            render: .sourceChapter(
                .init(versification: normalized, osisBookId: osisBookID, chapter: chapter),
                sourceVerse: sourceVerse
            )
        )
    }

    /** Returns Android's exact fake-document history key without reverse conversion. */
    static func historyKey(for intent: BibleReaderMyNotesIntent) -> String {
        intent.kjvaPosition.key
    }

    /** Builds an intro-aware exact KJVA position. */
    private static func kjvaPosition(
        _ reference: SwordVersification.Reference
    ) -> BibleReaderMyNotesKJVAPosition? {
        let ordinal: Int?
        if reference.verse == 0 {
            ordinal = JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: reference.osisBookId,
                chapter: reference.chapter
            )
        } else {
            ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: reference.osisBookId,
                chapter: reference.chapter,
                verse: reference.verse
            )
        }
        guard let ordinal else { return nil }
        return .init(
            osisBookID: reference.osisBookId,
            chapter: reference.chapter,
            verse: reference.verse,
            ordinal: ordinal
        )
    }
}
