// BibleWindowMenuReference.swift -- Android window-menu clipboard and speech destinations

import BibleCore
import Foundation
import SwordKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/**
 Immutable Android `BookAndKey` equivalent retained by the shared window popup.

 Android stores `clipboardKey` outside an individual popup so Copy reference in one window can
 expose Open reference in another. This value keeps the same source document/key identity while
 also carrying the proven Bible navigation contract needed to preserve versification boundaries.

 Inputs: exact source module/key metadata from a reader page or speech provider

 Outputs: one display label, durable AndBible URL, exact bookmark-style destination, and optional
 Bible passage used when the target is already showing a verse page

 Side effects: none

 Failure modes: factories return nil for empty generic identity or unverified Bible coordinates;
 they never reinterpret a source ordinal in KJVA or substitute current-pane state
 */
struct BibleWindowMenuReference {
    /// Android menu text inserted into `go_to_ref`.
    let displayName: String

    /// Durable URL copied to the platform clipboard by Copy reference.
    let urlString: String

    /// Exact cross-category destination used when the target is not already a verse page.
    let navigationTarget: BookmarkNavigationTarget

    /// Source-versification passage used when a Bible/commentary target keeps its own document.
    let bibleReference: OsisRef?

    /**
     Creates a proven single-position Bible reference.

     - Parameters:
       - displayName: Localized source-owned reference label.
       - sourceBookName: Human-readable source book name.
       - sourceOSISReference: Exact source OSIS verse.
       - verifiedRange: Source and KJVA ordinal proof from the active backend.
     - Returns: A reference carrying both source and KJVA navigation identity.
     - Side effects: Reads pinned versification metadata only.
     - Failure modes: Invalid source/KJVA ordinals or unresolved book identities return nil.
     */
    static func bible(
        displayName: String,
        sourceBookName: String,
        sourceOSISReference: String,
        verifiedRange: VerifiedKJVAOrdinalRange
    ) -> BibleWindowMenuReference? {
        guard
            let sourceStart = SwordVersification.reference(
                forIndex: verifiedRange.sourceOrdinalStart,
                versification: verifiedRange.sourceVersification
            ),
            let kjvaStart = JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: verifiedRange.kjvaOrdinalStart
            ),
            let kjvaEnd = JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: verifiedRange.kjvaOrdinalEnd
            )
        else {
            return nil
        }

        let sourceCoordinate = OsisVerseCoordinate(
            osisBookId: sourceStart.osisBookId,
            chapter: sourceStart.chapter,
            verse: sourceStart.verse
        )
        let bibleReference = OsisRef(
            book: sourceBookName,
            chapter: sourceStart.chapter,
            verse: sourceStart.verse,
            osisId: sourceStart.osisBookId,
            sourceVersification: verifiedRange.sourceVersification,
            targetBookInitials: nil,
            sourceVerses: [sourceCoordinate],
            sourceOsisRef: sourceOSISReference,
            endBook: sourceBookName
        )
        let kjvaReference = Self.osisRange(
            startBook: kjvaStart.osisId,
            startChapter: kjvaStart.chapter,
            startVerse: kjvaStart.verse,
            endBook: kjvaEnd.osisId,
            endChapter: kjvaEnd.chapter,
            endVerse: kjvaEnd.verse
        )
        let target = BibleBookmarkNavigationTarget(
            sourceModuleInitials: verifiedRange.sourceBookInitials,
            sourceVersification: verifiedRange.sourceVersification,
            sourceOrdinalRange: verifiedRange.sourceOrdinalStart...verifiedRange.sourceOrdinalEnd,
            sourceOSISReference: sourceOSISReference,
            kjvaOrdinalRange: verifiedRange.kjvaOrdinalStart...verifiedRange.kjvaOrdinalEnd,
            kjvaOSISReference: kjvaReference
        )
        guard let url = AndBibleReferenceURLBuilder.urlString(
            osisRef: sourceOSISReference,
            documentInitials: verifiedRange.sourceBookInitials,
            ordinal: verifiedRange.sourceOrdinalStart
        ) else {
            return nil
        }
        return BibleWindowMenuReference(
            displayName: displayName,
            urlString: url,
            navigationTarget: .bible(target),
            bibleReference: bibleReference
        )
    }

    /**
     Creates one exact non-Bible document/key reference.

     - Parameters:
       - displayName: Source-owned key label shown in the popup.
       - moduleInitials: Exact installed document identity.
       - key: Exact source key with spelling and whitespace preserved.
       - ordinalRange: Optional source-owned ordinal span.
     - Returns: A generic destination and durable AndBible URL, or nil for empty identity.
     - Side effects: None.
     - Failure modes: Empty module initials/key or URL construction failure returns nil.
     */
    static func generic(
        displayName: String,
        moduleInitials: String,
        key: String,
        ordinalRange: ClosedRange<Int>? = nil
    ) -> BibleWindowMenuReference? {
        guard !moduleInitials.isEmpty, !key.isEmpty,
              let url = AndBibleReferenceURLBuilder.urlString(
                  osisRef: key,
                  documentInitials: moduleInitials,
                  ordinal: ordinalRange?.lowerBound
              ) else {
            return nil
        }
        return BibleWindowMenuReference(
            displayName: displayName,
            urlString: url,
            navigationTarget: .generic(
                GenericBookmarkNavigationTarget(
                    moduleInitials: moduleInitials,
                    key: key,
                    ordinalRange: ordinalRange
                )
            ),
            bibleReference: nil
        )
    }

    /**
     Converts the live Speak provider position into Android's Go to speech-position destination.

     - Parameter position: Current source-owned speech cursor.
     - Returns: Proven Bible or exact generic reference, or nil for an unbound text selection.
     - Side effects: Reads pinned versification metadata only.
     - Failure modes: Missing verified Bible provenance and empty generic source identity fail closed.
     */
    static func speechPosition(_ position: SpeakStreamPosition) -> BibleWindowMenuReference? {
        if let verified = position.verifiedBibleRange,
           let source = SwordVersification.reference(
               forIndex: verified.sourceOrdinalStart,
               versification: verified.sourceVersification
           ) {
            let sourceOSIS = position.osisRef
                ?? "\(source.osisBookId).\(source.chapter).\(source.verse)"
            return bible(
                displayName: position.keyName,
                sourceBookName: position.bookName,
                sourceOSISReference: sourceOSIS,
                verifiedRange: verified
            )
        }

        switch position.category {
        case .commentary, .dictionary, .generalBook, .myDocument:
            return generic(
                displayName: position.keyName,
                moduleInitials: position.bookInitials,
                key: position.key,
                ordinalRange: Self.ordinalRange(
                    start: position.ordinalStart,
                    end: position.ordinalEnd
                )
            )
        case .bible, .memorization, .selection:
            return nil
        }
    }

    /// Formats Android/JSword full-endpoint OSIS ranges without losing cross-book identity.
    private static func osisRange(
        startBook: String,
        startChapter: Int,
        startVerse: Int,
        endBook: String,
        endChapter: Int,
        endVerse: Int
    ) -> String {
        let start = "\(startBook).\(startChapter).\(startVerse)"
        let end = "\(endBook).\(endChapter).\(endVerse)"
        return start == end ? start : "\(start)-\(end)"
    }

    /// Validates nullable generic speech ordinals without manufacturing a partial range.
    private static func ordinalRange(start: Int?, end: Int?) -> ClosedRange<Int>? {
        guard let start, let end, start >= 0, end >= start else { return nil }
        return start...end
    }
}

/**
 Reader-session owner for Android's shared `clipboardKey` behavior.

 The store is injected into every pane and the bottom restore strip. It is intentionally separate
 from the platform text pasteboard: the pasteboard contains the durable URL, while this store keeps
 the typed source identity Android needs for the later Open reference command.
 */
@MainActor
final class BibleWindowMenuReferenceStore {
    /// Most recently copied non-special document reference in this reader session.
    private(set) var reference: BibleWindowMenuReference?

    /**
     Copies one typed reference to both Android-equivalent stores.

     - Parameters:
       - reference: Proven reference produced from the target reader controller.
       - onShowToast: Owner callback for Android's localized confirmation.
     - Side effects: Replaces the in-memory typed reference, platform URL pasteboard, and toast.
     - Failure modes: None; factories prevent invalid references from reaching this boundary.
     */
    func copy(
        _ reference: BibleWindowMenuReference,
        onShowToast: ((String) -> Void)?
    ) {
        self.reference = reference
        #if os(iOS)
        UIPasteboard.general.string = reference.urlString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.urlString, forType: .string)
        #endif
        onShowToast?(
            String(
                localized: "reference_copied_to_clipboard",
                defaultValue: "Reference copied to clipboard"
            )
        )
    }
}
