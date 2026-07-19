// SwordVersification.swift - Cross-versification verse mapping through SWORD's VersificationMgr

import CLibSword
import Foundation

/**
 Maps verse references between Bible versifications using SWORD's built-in `VersificationMgr`.

 Android normalizes every bookmark, memorization, and progress ordinal into KJVA using JSword's
 `Versification.toV11n(KJVA)`. iOS mirrors that by routing source-versification references through
 SWORD's own `VersificationMgr::System::translateVerse`, which uses the same av11n mapping tables
 JSword ships. Because the mapping data is compiled into libsword, this works for every SWORD
 versification system regardless of which modules are installed.

 Thread safety: libsword is not thread-safe, so every mapping runs inside the shared `SwordRuntime`
 serialization queue.
 */
public enum SwordVersification {
    /// A verse reference resolved into the KJVA versification.
    public struct KJVAReference: Sendable, Equatable {
        /// KJVA OSIS book identifier, such as `Gen`, `Ps`, or `1Macc`.
        public let osisBookId: String

        /// One-based KJVA chapter number.
        public let chapter: Int

        /// KJVA verse number; `0` denotes a chapter superscription/introduction.
        public let verse: Int

        /**
         Creates a KJVA-mapped verse reference.

         - Parameters:
           - osisBookId: KJVA OSIS book identifier.
           - chapter: One-based KJVA chapter number.
           - verse: One-based KJVA verse number.
         - Side effects: none.
         - Failure modes: none.
         */
        public init(osisBookId: String, chapter: Int, verse: Int) {
            self.osisBookId = osisBookId
            self.chapter = chapter
            self.verse = verse
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
       - verse: One-based verse number in the source versification.
       - sourceVersification: SWORD versification name for the input reference; an empty string is
         treated as KJV, matching SWORD and Android defaults. A present-but-unrecognized name returns
         `nil`, matching Android's rejection of an unsupported module versification.
     - Returns: The KJVA reference (verse `0` for a chapter superscription/introduction), or `nil`
       when inputs are invalid, the source versification is unrecognized, or SWORD cannot map the
       reference into KJVA.
     - Side effects: Runs inside the SWORD serialization queue and reads SWORD's system
       versification manager.
     - Failure modes: Returns `nil` for non-positive chapter/verse input, an empty book id, an
       unrecognized source versification, or a mapped result with a non-positive chapter or negative
       verse.
     */
    public static func mapVerseToKJVA(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceVersification: String
    ) -> KJVAReference? {
        guard chapter > 0, verse > 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            var mappedBook: UnsafePointer<CChar>?
            var mappedChapter: Int32 = 0
            var mappedVerse: Int32 = 0

            let status = osisBookId.withCString { bookPointer in
                sourceVersification.withCString { versificationPointer in
                    SWVersification_mapVerseToKJVA(
                        versificationPointer,
                        bookPointer,
                        Int32(chapter),
                        Int32(verse),
                        &mappedBook,
                        &mappedChapter,
                        &mappedVerse
                    )
                }
            }

            guard status == 0, let mappedBook else { return nil }
            let bookId = String(cString: mappedBook)
            // A mapped verse of 0 is a valid KJVA chapter superscription/introduction: divergent
            // canons map a Psalm-title verse onto it (e.g. Septuagint/Vulgate/Synodal Ps 50:1 ->
            // KJVA Ps 51:0), exactly as JSword does on Android. Accept it so the caller can resolve
            // the reserved intro ordinal instead of failing into a raw-source-ordinal fallback; only
            // reject a non-positive chapter or an empty book.
            guard !bookId.isEmpty, mappedChapter > 0, mappedVerse >= 0 else { return nil }
            return KJVAReference(
                osisBookId: bookId,
                chapter: Int(mappedChapter),
                verse: Int(mappedVerse)
            )
        }
    }

    /// A verse reference resolved within an arbitrary (non-KJVA) versification.
    public struct VerseCoordinate: Sendable, Equatable {
        /// OSIS book identifier in the resolved versification.
        public let osisBookId: String

        /// One-based chapter number.
        public let chapter: Int

        /// Verse number; `0` denotes a chapter superscription/introduction.
        public let verse: Int

        /**
         Creates a versification-resolved verse reference.

         - Parameters:
           - osisBookId: OSIS book identifier.
           - chapter: One-based chapter number.
           - verse: Verse number (`0` for a chapter introduction).
         - Side effects: none.
         - Failure modes: none.
         */
        public init(osisBookId: String, chapter: Int, verse: Int) {
            self.osisBookId = osisBookId
            self.chapter = chapter
            self.verse = verse
        }
    }

    /**
     Maps a KJVA verse reference into a target versification (the reverse of `mapVerseToKJVA`).

     Mirrors Android's `Verse.toV11n(activeV11n)`: a stored KJVA ordinal is rendered, displayed, and
     navigated in the active module's versification, so divergent canons (LXX/Vulgate/Synodal and
     similar) resolve onto their true active-module verses rather than being re-interpreted under
     KJVA numbering. Used for highlight rendering, bookmark-list references, and navigation.

     - Parameters:
       - osisBookId: KJVA OSIS book identifier, such as `Ps` or `Gen`.
       - chapter: One-based KJVA chapter number.
       - verse: KJVA verse number (`0` for a chapter superscription/introduction).
       - targetVersification: SWORD versification name to map into; an empty string is treated as
         KJV, matching SWORD and Android defaults. A present-but-unrecognized name returns `nil`.
     - Returns: The target-versification reference, or `nil` when inputs are invalid, the target
       versification is unrecognized, or SWORD cannot map the reference.
     - Side effects: Runs inside the SWORD serialization queue and reads SWORD's system
       versification manager.
     - Failure modes: Returns `nil` for a non-positive chapter, a negative verse, an empty book id,
       an unrecognized target versification, or a mapped result outside the target's verse range.
     */
    public static func mapVerseFromKJVA(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        targetVersification: String
    ) -> VerseCoordinate? {
        guard chapter > 0, verse >= 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            var mappedBook: UnsafePointer<CChar>?
            var mappedChapter: Int32 = 0
            var mappedVerse: Int32 = 0

            let status = osisBookId.withCString { bookPointer in
                targetVersification.withCString { versificationPointer in
                    SWVersification_mapVerseFromKJVA(
                        versificationPointer,
                        bookPointer,
                        Int32(chapter),
                        Int32(verse),
                        &mappedBook,
                        &mappedChapter,
                        &mappedVerse
                    )
                }
            }

            guard status == 0, let mappedBook else { return nil }
            let bookId = String(cString: mappedBook)
            guard !bookId.isEmpty, mappedChapter > 0, mappedVerse >= 0 else { return nil }
            return VerseCoordinate(
                osisBookId: bookId,
                chapter: Int(mappedChapter),
                verse: Int(mappedVerse)
            )
        }
    }

    /**
     Decodes an intro-inclusive ordinal into its verse reference within a versification.

     Mirrors Android's `Verse(v11n, ordinal)`: a persisted source ordinal is resolved from the
     versification's own metadata, so a restored bookmark's original ordinal converts even when the
     module that produced it is not installed — matching this engine's module-independent goal.

     - Parameters:
       - versification: SWORD versification name owning `ordinal`; an empty string is treated as KJV.
         A present-but-unrecognized name returns `nil`.
       - ordinal: Intro-inclusive SWORD `VerseKey` index (the same scheme the module cursor uses).
     - Returns: The decoded reference, or `nil` when the versification is unrecognized or the ordinal
       is out of range or resolves to an introduction slot.
     - Side effects: Runs inside the SWORD serialization queue and reads SWORD's system
       versification manager.
     - Failure modes: Returns `nil` for a non-positive ordinal, an unrecognized versification, or an
       ordinal that does not round-trip to a real verse.
     */
    public static func decodeOrdinal(
        versification: String,
        ordinal: Int
    ) -> VerseCoordinate? {
        guard ordinal > 0 else { return nil }

        return SwordRuntime.sync {
            var decodedBook: UnsafePointer<CChar>?
            var decodedChapter: Int32 = 0
            var decodedVerse: Int32 = 0

            let status = versification.withCString { versificationPointer in
                SWVersification_decodeOrdinal(
                    versificationPointer,
                    CLong(ordinal),
                    &decodedBook,
                    &decodedChapter,
                    &decodedVerse
                )
            }

            guard status == 0, let decodedBook else { return nil }
            let bookId = String(cString: decodedBook)
            guard !bookId.isEmpty, decodedChapter > 0, decodedVerse > 0 else { return nil }
            return VerseCoordinate(
                osisBookId: bookId,
                chapter: Int(decodedChapter),
                verse: Int(decodedVerse)
            )
        }
    }
}
