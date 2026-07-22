// VersificationMapper.swift - Shared Android-compatible cross-versification conversion boundary

import SwordKit

/**
 Converts verse references and ordinals between module versifications and Android's KJVA storage
 domain.

 Android uses JSword's `VersificationConverter` whenever a bookmark, progress row, memorization
 row, reader payload, or cross-module action changes versification. This service gives iOS the same
 single boundary: JSword's mapping resources and bundled canon fixture define cross-canon
 equivalence, and `JSwordKJVAVersification` supplies Android's exact intro-inclusive KJVA ordinal
 address space. SWORD is consulted only when projecting a converted coordinate into an installed
 iOS module.

 Android's public converter can retain source coordinates in the target versification after a
 strict miss. The service exposes that result as `.fallback`, while strict persistence helpers
 reject it so bridge compatibility cannot silently corrupt stored target-domain ordinals.
 */
public enum VersificationMapper {
    /// Describes how JSword produced a target-versification reference.
    public enum Fidelity: String, Sendable, Equatable {
        /// At least one explicit JSword mapping rule participated in the conversion.
        case mapped

        /// Both canons address the same coordinate and no explicit rule was needed.
        case identity

        /// Strict conversion failed and Android's public converter retained the source coordinate.
        case fallback
    }

    /// Structured Android conversion result that keeps best-effort fallbacks visible to callers.
    public struct Conversion: Sendable, Equatable {
        /// Coordinates labeled with the requested target versification.
        public let reference: SwordVersification.Reference

        /// Whether the coordinates came from an explicit map, safe identity, or public fallback.
        public let fidelity: Fidelity

        /// Whether the result may be persisted as authoritative target-domain data.
        public var isAuthoritative: Bool { fidelity != .fallback }
    }

    /// Android-style projection of one KJVA verse into an installed module's ordinal domain.
    public struct ModuleProjection: Sendable, Equatable {
        /// Coordinates produced by JSword's public versification converter.
        public let reference: SwordVersification.Reference

        /// Ordinal in the target module, or `0` when the converted coordinate is not addressable.
        public let ordinal: Int

        /// Whether JSword used an explicit map, identity conversion, or coordinate fallback.
        public let fidelity: Fidelity

        /// Whether the target module can address the converted reference.
        public var isAddressable: Bool { ordinal > 0 }
    }

    /**
     Maps one source reference into a named target versification.

     - Parameters:
       - reference: Concrete reference whose coordinates belong to `sourceVersification`.
       - sourceVersification: SWORD versification name for the source coordinates.
       - targetVersification: SWORD versification name for the target coordinates.
     - Returns: Structured mapped, identity, or Android-compatible fallback result; `nil` for an
       unknown versification or a source whose book/chapter cannot construct a JSword verse.
     - Side effects: Lazily loads the pinned JSword canon and mapping resources.
     - Failure modes: A strict mapping miss returns `.fallback` with the source coordinates labeled
       for the target, matching Android's public converter. Persistence callers must require
       `isAuthoritative` or use `convertStrictly`.
     */
    public static func convert(
        reference: VerseKeyReference,
        from sourceVersification: String,
        to targetVersification: String
    ) -> Conversion? {
        convert(
            osisBookId: reference.osisBookId,
            chapter: reference.chapter,
            verse: reference.verse,
            from: sourceVersification,
            to: targetVersification
        )
    }

    /**
     Maps concrete OSIS coordinates between named versifications.

     - Parameters:
       - osisBookId: OSIS book identifier in `sourceVersification`.
       - chapter: One-based source chapter.
       - verse: Source verse, including `0` for a chapter introduction.
       - sourceVersification: SWORD versification name for the input.
       - targetVersification: SWORD versification name for the result.
     - Returns: Structured mapped, identity, or Android-compatible fallback result; `nil` for an
       unknown versification or a source whose book/chapter cannot construct a JSword verse.
     - Side effects: Lazily loads the pinned JSword canon and mapping resources.
     - Failure modes: Strict misses are explicit `.fallback` results and are never silently
       classified as authoritative.
     */
    public static func convert(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        from sourceVersification: String,
        to targetVersification: String
    ) -> Conversion? {
        let reference = SwordVersification.Reference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse
        )
        guard let sourceName = effectiveVersificationName(sourceVersification),
              effectiveVersificationName(targetVersification) != nil,
              JSwordCanon.canConstructReference(reference, versification: sourceName) else {
            return nil
        }
        if let strict = JSwordVersificationMapping.convertStrictly(
            reference: reference,
            from: sourceVersification,
            to: targetVersification
        ) {
            return Conversion(
                reference: strict.reference,
                fidelity: strict.usedExplicitMapping ? .mapped : .identity
            )
        }
        return Conversion(reference: reference, fidelity: .fallback)
    }

    /**
     Maps coordinates only when JSword has an authoritative explicit or identity conversion.

     - Parameters:
       - osisBookId: OSIS book identifier in `sourceVersification`.
       - chapter: One-based source chapter.
       - verse: Source verse, including `0` for a chapter introduction.
       - sourceVersification: SWORD versification name for the input.
       - targetVersification: SWORD versification name for the result.
     - Returns: An authoritative mapped or identity result, or `nil` when Android would need its
       coordinate-retaining public fallback.
     - Side effects: Lazily loads the pinned JSword canon and mapping resources.
     - Failure modes: Returns `nil` for invalid input, unknown systems, absent target equivalents,
       or malformed mapping resources.
     */
    public static func convertStrictly(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        from sourceVersification: String,
        to targetVersification: String
    ) -> Conversion? {
        guard let strict = JSwordVersificationMapping.convertStrictly(
            reference: .init(osisBookId: osisBookId, chapter: chapter, verse: verse),
            from: sourceVersification,
            to: targetVersification
        ) else {
            return nil
        }
        return Conversion(
            reference: strict.reference,
            fidelity: strict.usedExplicitMapping ? .mapped : .identity
        )
    }

    /**
     Projects a source-versification reference into Android's KJVA ordinal domain.

     Chapter introductions mapped to verse `0` use JSword's reserved intro slot immediately before
     verse 1. Normal verses use the source-derived KJVA canon table.

     - Parameters:
       - reference: Concrete source reference.
       - sourceVersification: SWORD versification name owning the source coordinates.
     - Returns: Intro-inclusive JSword KJVA ordinal, or `nil` when mapping or bounds validation
       fails.
     - Side effects: Lazily reads the pinned JSword canon and mapping resources.
     - Failure modes: Returns `nil`; callers must abort persistence instead of using the source
       ordinal as a substitute.
     */
    public static func kjvaOrdinal(
        for reference: VerseKeyReference,
        sourceVersification: String
    ) -> Int? {
        kjvaOrdinal(
            osisBookId: reference.osisBookId,
            chapter: reference.chapter,
            verse: reference.verse,
            sourceVersification: sourceVersification
        )
    }

    /**
     Projects concrete source coordinates into Android's KJVA ordinal domain.

     - Parameters:
       - osisBookId: OSIS book identifier in `sourceVersification`.
       - chapter: One-based source chapter.
       - verse: Source verse, including `0` for a chapter introduction.
       - sourceVersification: SWORD versification name owning the source coordinates.
     - Returns: Intro-inclusive JSword KJVA ordinal, or `nil` when conversion fails.
     - Side effects: Lazily reads the pinned JSword canon and mapping resources.
     - Failure modes: Returns `nil`; no identity fallback is applied.
     */
    public static func kjvaOrdinal(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceVersification: String
    ) -> Int? {
        guard let conversion = convertStrictly(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            from: sourceVersification,
            to: JSwordKJVAVersification.name
        ) else {
            return nil
        }
        let mapped = conversion.reference
        if mapped.verse == 0 {
            return JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: mapped.osisBookId,
                chapter: mapped.chapter
            )
        }
        return JSwordKJVAVersification.verseOrdinal(
            osisId: mapped.osisBookId,
            chapter: mapped.chapter,
            verse: mapped.verse
        )
    }

    /**
     Projects an inclusive source-reference range into Android's KJVA ordinal domain.

     Android converts range endpoints independently through JSword and stores the ordered KJVA
     endpoints. This method mirrors that rule and preserves ordering even when a divergent mapping
     reverses endpoint values.

     - Parameters:
       - start: First source reference.
       - end: Last source reference.
       - sourceVersification: SWORD versification name owning both endpoints.
     - Returns: Ordered inclusive KJVA range, or `nil` if either endpoint is unmappable.
     - Side effects: Lazily reads the pinned JSword canon and mapping resources.
     - Failure modes: Returns `nil` atomically; it never returns a partially converted range.
     */
    public static func kjvaOrdinalRange(
        start: VerseKeyReference,
        end: VerseKeyReference,
        sourceVersification: String
    ) -> ClosedRange<Int>? {
        guard let startOrdinal = kjvaOrdinal(for: start, sourceVersification: sourceVersification),
              let endOrdinal = kjvaOrdinal(for: end, sourceVersification: sourceVersification) else {
            return nil
        }
        return min(startOrdinal, endOrdinal)...max(startOrdinal, endOrdinal)
    }

    /**
     Converts an Android KJVA verse ordinal into a named target-versification reference.

     - Parameters:
       - ordinal: JSword KJVA ordinal for a real verse.
       - targetVersification: SWORD versification name for the target reference.
     - Returns: Target reference, including concrete book/chapter introductions, or `nil` for
       pseudo-book/out-of-domain ordinals and unavailable mappings.
     - Side effects: Lazily reads the pinned JSword canon and mapping resources.
     - Failure modes: Returns `nil`; a KJVA ordinal is never reinterpreted directly in the target.
     */
    public static func reference(
        forKJVAOrdinal ordinal: Int,
        targetVersification: String
    ) -> SwordVersification.Reference? {
        guard let source = JSwordKJVAVersification.referenceIncludingIntroductions(
            ordinal: ordinal
        ) else {
            return nil
        }
        return convert(
            osisBookId: source.osisId,
            chapter: source.chapter,
            verse: source.verse,
            from: JSwordKJVAVersification.name,
            to: targetVersification
        )?.reference
    }

    /**
     Converts an Android KJVA verse ordinal into an installed target module's ordinal.

     - Parameters:
       - ordinal: JSword KJVA ordinal for a real verse.
       - targetModule: Installed SWORD module whose versification owns the returned ordinal.
     - Returns: Exact target-module ordinal, or `nil` when the KJVA reference cannot be converted or
       the target module does not address the mapped verse.
     - Side effects: Reads and temporarily moves the target SWORD module cursor under the shared
       serialization queue; the module restores its prior key before returning.
     - Failure modes: Returns `nil` without using the KJVA ordinal in the target module directly.
     */
    public static func moduleOrdinal(
        forKJVAOrdinal ordinal: Int,
        targetModule: SwordModule
    ) -> Int? {
        guard let projection = moduleProjection(
            forKJVAOrdinal: ordinal,
            targetModule: targetModule
        ), projection.isAddressable else { return nil }
        return projection.ordinal
    }

    /**
     Projects an Android KJVA ordinal through JSword's public converter into a SWORD module.

     Android converts event and bookmark ordinals with `Verse.toV11n(target)` and then reads the
     resulting verse ordinal. Its public converter retains source coordinates when no strict map
     exists; JSword reports ordinal `0` when those coordinates are not addressable by the target.
     Keeping that sentinel explicit prevents callers from reusing the KJVA ordinal in the target
     module while preserving Android's bridge behavior.

     - Parameters:
       - ordinal: JSword KJVA ordinal for a real verse.
       - targetModule: Installed SWORD module whose versification owns the returned projection.
     - Returns: Converted target reference, target ordinal, and conversion fidelity, or `nil` for
       invalid KJVA ordinals and unsupported target versifications.
     - Side effects: Reads and temporarily moves the target module cursor; the module restores its
       prior key before returning.
     - Failure modes: Unaddressable public-fallback coordinates return ordinal `0`; they are never
       relabeled with the input KJVA ordinal.
     */
    public static func moduleProjection(
        forKJVAOrdinal ordinal: Int,
        targetModule: SwordModule
    ) -> ModuleProjection? {
        guard let source = JSwordKJVAVersification.referenceIncludingIntroductions(
                  ordinal: ordinal
              ),
              let conversion = convert(
                  osisBookId: source.osisId,
                  chapter: source.chapter,
                  verse: source.verse,
                  from: JSwordKJVAVersification.name,
                  to: versificationName(for: targetModule)
              ) else {
            return nil
        }
        let target = conversion.reference
        let targetOrdinal = targetModule.verseOrdinal(
            osisBookId: target.osisBookId,
            chapter: target.chapter,
            verse: target.verse
        ) ?? 0
        return ModuleProjection(
            reference: target,
            ordinal: targetOrdinal,
            fidelity: conversion.fidelity
        )
    }

    /**
     Returns the effective SWORD versification name for an installed module.

     SWORD and Android use KJV when a module omits `Versification`, so callers should use this
     helper instead of preserving an empty metadata string in conversion requests.

     - Parameter module: Installed SWORD module whose metadata should be inspected.
     - Returns: Trimmed configured versification name, or `KJV` when omitted.
     - Side effects: None; reads metadata captured when the module was loaded.
     - Failure modes: This helper cannot fail.
     */
    public static func versificationName(for module: SwordModule) -> String {
        let configured = module.info.aboutMetadata.versification
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? "KJV" : configured
    }

    /**
     Reports whether Android's pinned JSword dependency defines a named versification.

     - Parameter name: Raw module or payload versification name; empty means KJV.
     - Returns: `true` only when the bundled JSword canon fixture contains the system.
     - Side effects: Decodes the canon fixture on first access.
     - Failure modes: Missing or revision-mismatched fixture data returns `false`.
     */
    public static func supports(_ name: String) -> Bool {
        JSwordCanon.normalizedName(name) != nil
    }

    private static func effectiveVersificationName(_ name: String) -> String? {
        JSwordCanon.normalizedName(name)
    }
}
