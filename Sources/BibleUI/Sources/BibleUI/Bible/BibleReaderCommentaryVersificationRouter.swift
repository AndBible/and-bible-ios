// BibleReaderCommentaryVersificationRouter.swift -- Commentary conversion and exact lookup

import BibleCore
import SwordKit

/**
 Resolves ephemeral commentary coordinates with Android's public versification fallback.

 Android uses the public JSword converter for commentary display and navigation, then asks the
 destination document whether the resulting key exists. The resolver keeps both requirements in
 one boundary so fallback coordinates are never accepted without target addressability.
 */
enum BibleReaderCommentaryVersificationRouter {
    /**
     Converts one coordinate and resolves it through an exact destination-owned lookup.

     - Parameters:
       - reference: Source-versification coordinate selected by the current document.
       - sourceVersification: JSword versification that owns the source coordinate.
       - destinationVersification: JSword versification that owns the destination lookup.
       - resolve: Exact destination lookup; returning nil rejects the mapped or fallback coordinate.
     - Returns: Destination-owned value for the converted coordinate, or nil.
     - Side effects: Reads pinned versification resources and invokes the supplied lookup once.
     - Failure modes: Invalid versifications, invalid source coordinates, and unavailable exact
       destination keys return nil. The resolver never searches neighboring keys.
     */
    static func resolve<Value>(
        reference: SwordVersification.Reference,
        from sourceVersification: String,
        to destinationVersification: String,
        resolve: (SwordVersification.Reference) -> Value?
    ) -> Value? {
        guard let mapped = VersificationMapper.convert(
            osisBookId: reference.osisBookId,
            chapter: reference.chapter,
            verse: reference.verse,
            from: sourceVersification,
            to: destinationVersification
        )?.reference else {
            return nil
        }
        return resolve(mapped)
    }
}
