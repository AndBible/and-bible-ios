// SwordVersification.swift - Cross-versification verse mapping through SWORD's VersificationMgr

import CLibSword
import Foundation

/**
 Exposes SWORD canon metadata and built-in verse mappings.

 Android normalizes every bookmark, memorization, and progress ordinal into KJVA using JSword's
 `Versification.toV11n(KJVA)`. SWORD's `VersificationMgr::System::translateVerse` covers several of
 those mappings, but not every JSword canon. BibleCore's `VersificationMapper` overlays Android's
 authoritative JSword resources; callers seeking Android behavior must use that service. The
 lower-level APIs here also expose SWORD canon indexes so the overlay can expand mapping ranges
 without requiring installed modules.

 Thread safety: libsword is not thread-safe, so every mapping runs inside the shared `SwordRuntime`
 serialization queue.
 */
public enum SwordVersification {
    /// A verse reference resolved into a named target versification.
    public struct Reference: Sendable, Equatable {
        /// OSIS book identifier in the target versification, such as `Gen`, `Ps`, or `1Macc`.
        public let osisBookId: String

        /// One-based target chapter number.
        public let chapter: Int

        /// Target verse number; `0` denotes a chapter superscription/introduction.
        public let verse: Int

        /**
         Creates a mapped verse reference whose coordinates are already validated by SWORD.

         - Parameters:
           - osisBookId: OSIS book identifier in the target versification.
           - chapter: One-based target chapter number.
           - verse: Target verse number, including `0` for chapter introductions.
         - Side effects: None.
         - Failure modes: None; the SWORD mapping boundary validates values before construction.
         */
        public init(osisBookId: String, chapter: Int, verse: Int) {
            self.osisBookId = osisBookId
            self.chapter = chapter
            self.verse = verse
        }
    }

    /// A verse reference resolved into the KJVA versification.
    public typealias KJVAReference = Reference

    /// Compatibility name for a reference resolved within an arbitrary versification.
    public typealias VerseCoordinate = Reference

    /**
     Maps a verse reference from one named versification into another.

     This method exposes SWORD's `translateVerse` boundary. It is useful for SWORD-native behavior,
     but it is not a complete substitute for Android's JSword resource mapper; BibleCore feature
     code should use `VersificationMapper`.

     - Parameters:
       - osisBookId: OSIS book identifier in `sourceVersification`.
       - chapter: One-based source chapter number.
       - verse: Source verse number; `0` represents a chapter introduction.
       - sourceVersification: SWORD versification name for the input reference. Empty uses KJV;
         an unknown non-empty name fails.
       - targetVersification: SWORD versification name for the output reference. Empty means KJV.
     - Returns: The mapped target reference, or `nil` when the input is invalid, the target
       versification is unknown, or SWORD cannot map the verse.
     - Side effects: Runs synchronously on the shared SWORD serialization queue and reads SWORD's
       compiled versification mapping tables.
     - Failure modes: Returns `nil` rather than returning source coordinates as a target-domain
       fallback. Callers must not persist or emit an unconverted ordinal after failure.
     */
    public static func mapVerse(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceVersification: String,
        targetVersification: String
    ) -> Reference? {
        guard chapter > 0, verse >= 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            var mappedBook: UnsafePointer<CChar>?
            var mappedChapter: Int32 = 0
            var mappedVerse: Int32 = 0

            let status = osisBookId.withCString { bookPointer in
                sourceVersification.withCString { sourcePointer in
                    targetVersification.withCString { targetPointer in
                        SWVersification_mapVerse(
                            sourcePointer,
                            targetPointer,
                            bookPointer,
                            Int32(chapter),
                            Int32(verse),
                            &mappedBook,
                            &mappedChapter,
                            &mappedVerse
                        )
                    }
                }
            }

            guard status == 0, let mappedBook else { return nil }
            let bookId = String(cString: mappedBook)
            guard !bookId.isEmpty, mappedChapter > 0, mappedVerse >= 0 else { return nil }
            return Reference(
                osisBookId: bookId,
                chapter: Int(mappedChapter),
                verse: Int(mappedVerse)
            )
        }
    }

    /**
     Maps a source-versification verse reference into KJVA.

     Uses SWORD's `VersificationMgr` to translate the reference the way Android's JSword
     `toV11n(KJVA)` does: shared canonical books stay aligned, while divergent canons
     (LXX/Vulgate/Synodal and similar) are remapped verse-by-verse through SWORD's mapping tables,
     and out-of-range references clamp to the nearest valid KJVA verse.

     - Parameters:
       - osisBookId: OSIS book identifier in the source versification, such as `Ps` or `Gen`.
       - chapter: One-based chapter number in the source versification.
       - verse: Source verse number; `0` represents a chapter introduction.
       - sourceVersification: SWORD versification name for the input reference; an empty string is
         treated as KJV, matching SWORD and Android defaults. An unknown non-empty name fails.
     - Returns: The KJVA reference (verse `0` for a chapter superscription/introduction), or `nil`
       when inputs are invalid or SWORD cannot map the reference into KJVA.
     - Side effects: Runs inside the SWORD serialization queue and reads SWORD's system
       versification manager.
     - Failure modes: Returns `nil` for a non-positive chapter, negative verse, empty book id, or a
       mapped result with a non-positive chapter or negative verse.
     */
    public static func mapVerseToKJVA(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceVersification: String
    ) -> KJVAReference? {
        mapVerse(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            sourceVersification: sourceVersification,
            targetVersification: "KJVA"
        )
    }

    /**
     Maps a KJVA reference into a named target versification.

     This convenience boundary preserves the public API introduced with active bookmark
     projection while delegating to the strict generalized mapper. Unknown targets return `nil`;
     they are never treated as KJV.

     - Parameters:
       - osisBookId: KJVA OSIS book identifier.
       - chapter: One-based KJVA chapter.
       - verse: KJVA verse, including `0` for a chapter introduction.
       - targetVersification: SWORD versification name for the result; empty means KJV.
     - Returns: Exact target reference, or `nil` for invalid input or an unknown target.
     - Side effects: Reads SWORD's mapping tables on the shared serialization queue.
     - Failure modes: Returns `nil`; no coordinate-retaining or KJV relabeling fallback is applied.
     */
    public static func mapVerseFromKJVA(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        targetVersification: String
    ) -> VerseCoordinate? {
        mapVerse(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            sourceVersification: "KJVA",
            targetVersification: targetVersification
        )
    }

    /**
     Resolves a valid reference to its intro-inclusive index in a named canon.

     This is the range-enumeration primitive used by the Android JSword mapping-table port. It
     deliberately exposes SWORD's canon dimensions without applying SWORD's verse mappings.

     - Parameters:
       - reference: Reference whose coordinates belong to `versification`.
       - versification: SWORD versification name. Empty means KJV.
     - Returns: Intro-inclusive canon index, or `nil` for an unknown versification or invalid
       coordinates.
     - Side effects: Reads SWORD's compiled canon tables on the shared serialization queue.
     - Failure modes: Returns `nil`; it never clamps an out-of-range coordinate.
     */
    public static func referenceIndex(
        for reference: Reference,
        versification: String
    ) -> Int? {
        SwordRuntime.sync {
            var index: Int = -1
            let status = reference.osisBookId.withCString { bookPointer in
                versification.withCString { versificationPointer in
                    SWVersification_getReferenceIndex(
                        versificationPointer,
                        bookPointer,
                        Int32(reference.chapter),
                        Int32(reference.verse),
                        &index
                    )
                }
            }
            return status == 0 ? index : nil
        }
    }

    /**
     Resolves an intro-inclusive canon index to a chapter or verse reference.

     - Parameters:
       - index: Canon index produced by `referenceIndex(for:versification:)`.
       - versification: SWORD versification name. Empty means KJV.
     - Returns: Chapter introduction or verse reference, or `nil` for an unknown versification,
       invalid index, or non-reference heading slot.
     - Side effects: Reads SWORD's compiled canon tables on the shared serialization queue.
     - Failure modes: Returns `nil`; module, testament, and book heading indexes are not references.
     */
    public static func reference(
        forIndex index: Int,
        versification: String
    ) -> Reference? {
        SwordRuntime.sync {
            var book: UnsafePointer<CChar>?
            var chapter: Int32 = 0
            var verse: Int32 = 0
            let status = versification.withCString { versificationPointer in
                SWVersification_getReferenceForIndex(
                    versificationPointer,
                    index,
                    &book,
                    &chapter,
                    &verse
                )
            }
            guard status == 0, let book else { return nil }
            return Reference(
                osisBookId: String(cString: book),
                chapter: Int(chapter),
                verse: Int(verse)
            )
        }
    }

    /**
     Resolves a positive intro-inclusive ordinal in a named SWORD canon.

     - Parameters:
       - versification: SWORD versification name; empty means KJV.
       - ordinal: Positive canon index.
     - Returns: Exact chapter-introduction or verse reference, or `nil` for an unknown system,
       invalid index, or heading slot.
     - Side effects: Reads SWORD's canon tables on the shared serialization queue.
     - Failure modes: Returns `nil`; unknown systems do not fall back to KJV.
     */
    public static func decodeOrdinal(
        versification: String,
        ordinal: Int
    ) -> VerseCoordinate? {
        guard ordinal > 0 else { return nil }
        return reference(forIndex: ordinal, versification: versification)
    }

    /**
     Reports whether SWORD ships a canon definition for a versification name.

     - Parameter versification: SWORD versification name. Empty means KJV.
     - Returns: `true` when the system canon exists.
     - Side effects: Reads SWORD's system versification registry on the serialization queue.
     - Failure modes: Returns `false` when the registry is unavailable or the name is unknown.
     */
    public static func supports(_ versification: String) -> Bool {
        SwordRuntime.sync {
             versification.withCString { pointer in
                 SWVersification_hasSystem(pointer) == 1
             }
        }
    }

    /**
     Reports whether SWORD defines a named versification.

     - Parameter versification: SWORD versification name; empty means KJV.
     - Returns: The same strict registry result as `supports(_:)`.
     - Side effects: Reads SWORD's registry on the shared serialization queue.
     - Failure modes: Returns `false` when the registry is unavailable or the name is unknown.
     */
    public static func isVersificationDefined(_ versification: String) -> Bool {
        supports(versification)
    }
}
