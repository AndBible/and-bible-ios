// JSwordVersificationAddress.swift - Strict source-versification coordinate validation

/**
 Validates Bible coordinates against Android's pinned JSword canon dimensions.

 This boundary answers only whether the source versification can address the exact coordinate. It
 does not convert the coordinate to KJVA, so books and chapters unique to another versification
 remain valid when that versification contains them.
 */
public enum JSwordVersificationAddress {
    /**
     Returns whether a source versification contains the complete Bible coordinate.

     Chapter and verse introductions are represented explicitly by zero. A caller with no stored
     verse must not substitute zero before calling this method because absence and an introduction
     are different states.

     - Parameters:
       - osisBookID: Exact OSIS book identifier in the source versification.
       - chapter: Zero for an introduction chapter or a one-based real chapter.
       - verse: Zero for an introduction verse or a one-based real verse.
       - versification: JSword system name; whitespace-only input means KJV.
     - Returns: `true` only when the pinned JSword dimensions contain the book, chapter, and verse.
     - Side effects: Lazily decodes the immutable bundled canon fixture; it performs no native I/O
       and changes no caller-visible state.
     - Failure modes: Negative coordinates, unknown systems or books, out-of-range chapters or
       verses, and unavailable fixture data return `false`.
     */
    public static func isValid(
        osisBookID: String,
        chapter: Int,
        verse: Int,
        versification: String
    ) -> Bool {
        guard verse >= 0,
              let lastVerse = JSwordCanon.lastVerse(
                  osisBookId: osisBookID,
                  chapter: chapter,
                  versification: versification
              ) else {
            return false
        }
        return verse <= lastVerse
    }
}
