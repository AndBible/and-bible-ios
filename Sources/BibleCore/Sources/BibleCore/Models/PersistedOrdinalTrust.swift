// PersistedOrdinalTrust.swift -- Durable provenance for persisted KJVA ordinals

import Foundation
import SwordKit

/**
 Describes whether persisted KJVA ordinals may be consumed as authoritative coordinates.

 The raw value is stored in SwiftData and JSON so legacy rows remain quarantined until a migration
 can establish their source. Unknown future values must decode as `legacyUnresolved`.
 */
public enum PersistedOrdinalTrustState: String, Codable, Sendable, Equatable {
    /// KJVA coordinates read from Android after explicit bounds validation.
    case verifiedAndroid

    /// KJVA coordinates produced by the version-one strict mapping boundary.
    case verifiedMappingV1

    /// Legacy source coordinates whose named module is not currently installed.
    case legacyPendingModule

    /// Legacy coordinates whose provenance cannot be established safely.
    case legacyUnresolved

    /// Whether this state permits consumers to use the stored KJVA coordinates.
    public var isVerified: Bool {
        self == .verifiedAndroid || self == .verifiedMappingV1
    }
}

/**
 Identifies the boundary that established a persisted ordinal's provenance.

 This value is diagnostic as well as defensive: a verified state is accepted only with the
 matching provenance and mapping version.
 */
public enum PersistedOrdinalProvenance: String, Codable, Sendable, Equatable {
    /// No trustworthy source boundary is known.
    case unknown

    /// A native write supplied exact source metadata and strict KJVA mapping output.
    case nativeMapping

    /// A validated Android database or remote patch supplied the KJVA coordinates.
    case androidImport

    /// Startup migration reconstructed KJVA coordinates from an installed source module.
    case legacyMigration
}

/**
 Stores the durable trust decision and exact source coordinates behind a KJVA range.

 `sourceOrdinalStart` and `sourceOrdinalEnd` are intentionally retained after migration. They let
 future mapping versions re-evaluate a row without treating its current KJVA values as provenance.
 */
public struct PersistedOrdinalTrustMetadata: Codable, Sendable, Equatable, Hashable {
    /// Durable trust state for the KJVA coordinates.
    public let state: PersistedOrdinalTrustState

    /// Mapping contract version that produced the current KJVA coordinates, or zero when unmapped.
    public let mappingVersion: Int

    /// Boundary that established the current trust decision.
    public let provenance: PersistedOrdinalProvenance

    /// Exact source module initials, or a domain marker such as `KJVA` when no module was involved.
    public let sourceBookInitials: String?

    /// Exact SWORD versification owning the source ordinals.
    public let sourceVersification: String?

    /// Original source-domain start ordinal.
    public let sourceOrdinalStart: Int?

    /// Original source-domain end ordinal.
    public let sourceOrdinalEnd: Int?

    /**
     Creates durable ordinal trust metadata.

     - Parameters:
       - state: Trust state for the persisted KJVA coordinates.
       - mappingVersion: Mapping contract version, or zero for unresolved legacy data.
       - provenance: Boundary that established the trust decision.
       - sourceBookInitials: Exact source module initials or domain marker.
       - sourceVersification: Exact source versification name.
       - sourceOrdinalStart: Original source-domain start ordinal.
       - sourceOrdinalEnd: Original source-domain end ordinal.
     - Side effects: none.
     - Failure modes: This initializer does not validate the supplied combination; consumers must
       use `PersistedOrdinalTrustPolicy` before trusting persisted coordinates.
     */
    init(
        state: PersistedOrdinalTrustState,
        mappingVersion: Int,
        provenance: PersistedOrdinalProvenance,
        sourceBookInitials: String?,
        sourceVersification: String?,
        sourceOrdinalStart: Int?,
        sourceOrdinalEnd: Int?
    ) {
        self.state = state
        self.mappingVersion = mappingVersion
        self.provenance = provenance
        self.sourceBookInitials = sourceBookInitials
        self.sourceVersification = sourceVersification
        self.sourceOrdinalStart = sourceOrdinalStart
        self.sourceOrdinalEnd = sourceOrdinalEnd
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case mappingVersion
        case provenance
        case sourceBookInitials
        case sourceVersification
        case sourceOrdinalStart
        case sourceOrdinalEnd
    }

    /**
     Decodes trust metadata while treating unknown future state/provenance values as unresolved.

     - Parameter decoder: Decoder containing persisted trust metadata.
     - Side effects: none.
     - Failure modes: Structural decoding errors are rethrown; unknown enum raw values do not throw.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decodeIfPresent(String.self, forKey: .state)
        let decodedState = rawState.flatMap(PersistedOrdinalTrustState.init(rawValue:)) ?? .legacyUnresolved
        let rawProvenance = try container.decodeIfPresent(String.self, forKey: .provenance)
        let decodedProvenance = rawProvenance.flatMap(PersistedOrdinalProvenance.init(rawValue:)) ?? .unknown

        state = decodedState
        mappingVersion = decodedState.isVerified
            ? try container.decodeIfPresent(Int.self, forKey: .mappingVersion) ?? 0
            : 0
        provenance = decodedProvenance
        sourceBookInitials = try container.decodeIfPresent(String.self, forKey: .sourceBookInitials)
        sourceVersification = try container.decodeIfPresent(String.self, forKey: .sourceVersification)
        sourceOrdinalStart = try container.decodeIfPresent(Int.self, forKey: .sourceOrdinalStart)
        sourceOrdinalEnd = try container.decodeIfPresent(Int.self, forKey: .sourceOrdinalEnd)
    }

    /**
     Encodes the complete trust decision and retained source metadata.

     - Parameter encoder: Encoder receiving the persisted trust object.
     - Side effects: Writes to the supplied encoder only.
     - Failure modes: Rethrows encoder failures.
     */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.rawValue, forKey: .state)
        try container.encode(mappingVersion, forKey: .mappingVersion)
        try container.encode(provenance.rawValue, forKey: .provenance)
        try container.encodeIfPresent(sourceBookInitials, forKey: .sourceBookInitials)
        try container.encodeIfPresent(sourceVersification, forKey: .sourceVersification)
        try container.encodeIfPresent(sourceOrdinalStart, forKey: .sourceOrdinalStart)
        try container.encodeIfPresent(sourceOrdinalEnd, forKey: .sourceOrdinalEnd)
    }
}

/**
 Carries one complete, validated native source-to-KJVA write contract.

 Native callers that mapped a module-local selection into KJVA must use this value when writing
 memorization rows. Keeping both domains prevents a numerically plausible KJVA range from being
 mistaken for provenance and leaves enough source metadata for a future mapping revision.
 */
public struct VerifiedKJVAOrdinalRange: Sendable, Equatable, Hashable {
    /// Exact module initials that supplied the source-domain endpoints.
    public let sourceBookInitials: String

    /// Supported JSword versification that owns the source-domain endpoints.
    public let sourceVersification: String

    /// Inclusive source-domain start ordinal proven by `sourceReferenceStart`.
    public let sourceOrdinalStart: Int

    /// Inclusive source-domain end ordinal proven by `sourceReferenceEnd`.
    public let sourceOrdinalEnd: Int

    /// Inclusive start ordinal produced in the KJVA persistence domain.
    public let kjvaOrdinalStart: Int

    /// Inclusive end ordinal produced in the KJVA persistence domain.
    public let kjvaOrdinalEnd: Int

    /// Complete mapping-version-one provenance retained with the persisted row.
    public let ordinalTrust: PersistedOrdinalTrustMetadata

    /**
     Resolves exact source references internally and creates a verified native mapping contract.

     This convenience boundary accepts no candidate KJVA values. It reconstructs both source
     references from the pinned JSword canon and derives the KJVA range itself, preventing callers
     from pairing unrelated but numerically valid domains.

     - Parameters:
       - sourceBookInitials: Exact module initials that own the source ordinals.
       - sourceVersification: Actual supported SWORD versification for that module.
       - sourceOrdinalStart: Inclusive module-local source start ordinal.
       - sourceOrdinalEnd: Inclusive module-local source end ordinal.
     - Returns: A verified range, or `nil` when source metadata is incomplete, unsupported, or
       unmappable.
     - Side effects: Reads the bundled pinned JSword canon and mapping resources.
     - Failure modes: Invalid or reversed source ranges and unknown versifications fail closed.
     */
    public init?(
        resolvingSourceBookInitials sourceBookInitials: String,
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int
    ) {
        guard sourceOrdinalEnd >= sourceOrdinalStart,
              let sourceStart = Self.sourceReference(
                  forSourceOrdinal: sourceOrdinalStart,
                  sourceVersification: sourceVersification
              ),
              let sourceEnd = Self.sourceReference(
                  forSourceOrdinal: sourceOrdinalEnd,
                  sourceVersification: sourceVersification
              ) else {
            return nil
        }
        self.init(
            sourceBookInitials: sourceBookInitials,
            sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd,
            sourceReferenceStart: sourceStart,
            sourceReferenceEnd: sourceEnd
        )
    }

    /**
     Creates an explicit native mapping boundary from exact source and mapped coordinates.

     - Parameters:
       - sourceBookInitials: Exact module initials that supplied the source ordinals.
       - sourceVersification: Actual supported SWORD versification for that module.
       - sourceOrdinalStart: Original module-local start ordinal.
       - sourceOrdinalEnd: Original module-local end ordinal.
       - sourceReferenceStart: Exact resolved source reference for `sourceOrdinalStart`.
       - sourceReferenceEnd: Exact resolved source reference for `sourceOrdinalEnd`.
     - Returns: A verified range when every source field and KJVA endpoint is valid; otherwise
       `nil`, preventing the caller from persisting an unverified native row.
     - Side effects: Reads the bundled pinned JSword canon registry.
     - Failure modes: Missing module identity, unknown versification, invalid source coordinates,
       mismatched source references, and unmappable KJVA ranges fail closed with `nil`.
     */
    public init?(
        sourceBookInitials: String,
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int,
        sourceReferenceStart: VerseKeyReference,
        sourceReferenceEnd: VerseKeyReference
    ) {
        guard sourceOrdinalEnd >= sourceOrdinalStart,
              sourceReferenceStart.ordinal == sourceOrdinalStart,
              sourceReferenceEnd.ordinal == sourceOrdinalEnd,
              let canonicalSourceStart = Self.sourceReference(
                  forSourceOrdinal: sourceOrdinalStart,
                  sourceVersification: sourceVersification
              ),
              let canonicalSourceEnd = Self.sourceReference(
                  forSourceOrdinal: sourceOrdinalEnd,
                  sourceVersification: sourceVersification
              ),
              canonicalSourceStart.osisBookId == sourceReferenceStart.osisBookId,
              canonicalSourceStart.chapter == sourceReferenceStart.chapter,
              canonicalSourceStart.verse == sourceReferenceStart.verse,
              canonicalSourceEnd.osisBookId == sourceReferenceEnd.osisBookId,
              canonicalSourceEnd.chapter == sourceReferenceEnd.chapter,
              canonicalSourceEnd.verse == sourceReferenceEnd.verse,
              let mappedRange = VersificationMapper.kjvaOrdinalRange(
                  start: sourceReferenceStart,
                  end: sourceReferenceEnd,
                  sourceVersification: sourceVersification
              ) else {
            return nil
        }
        let metadata = PersistedOrdinalTrustPolicy.nativeMappingMetadata(
            sourceBookInitials: sourceBookInitials,
            sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd,
            kjvaOrdinalStart: mappedRange.lowerBound,
            kjvaOrdinalEnd: mappedRange.upperBound
        )
        guard PersistedOrdinalTrustPolicy.isTrustedKJVARange(
            metadata: metadata,
            start: mappedRange.lowerBound,
            end: mappedRange.upperBound
        ),
        let normalizedBookInitials = metadata.sourceBookInitials,
        let normalizedVersification = metadata.sourceVersification,
        let normalizedSourceStart = metadata.sourceOrdinalStart,
        let normalizedSourceEnd = metadata.sourceOrdinalEnd else {
            return nil
        }

        self.sourceBookInitials = normalizedBookInitials
        self.sourceVersification = normalizedVersification
        self.sourceOrdinalStart = normalizedSourceStart
        self.sourceOrdinalEnd = normalizedSourceEnd
        self.kjvaOrdinalStart = mappedRange.lowerBound
        self.kjvaOrdinalEnd = mappedRange.upperBound
        self.ordinalTrust = metadata
    }

    /**
     Revalidates a persisted trusted range from its retained source coordinates.

     This boundary is used before deriving local subsets from an existing row. It reconstructs the
     exact source references, reruns mapping version one, and requires the result to equal both
     persisted KJVA endpoints. The returned range uses native-mapping provenance because the
     current process has performed the mapping again.

     - Parameters:
       - kjvaOrdinalStart: Persisted inclusive KJVA start ordinal.
       - kjvaOrdinalEnd: Persisted inclusive KJVA end ordinal.
       - ordinalTrust: Existing complete trust and source metadata.
     - Returns: A newly verified range, or `nil` when any retained field no longer proves the
       persisted KJVA coordinates.
     - Side effects: Reads the bundled pinned JSword canon and mapping resources.
     - Failure modes: Untrusted metadata, unavailable source coordinates, unknown versification,
       and mapping drift fail closed with `nil`.
     */
    init?(
        revalidatingKJVAOrdinalStart kjvaOrdinalStart: Int,
        kjvaOrdinalEnd: Int,
        ordinalTrust: PersistedOrdinalTrustMetadata
    ) {
        guard PersistedOrdinalTrustPolicy.isTrustedKJVARange(
            metadata: ordinalTrust,
            start: kjvaOrdinalStart,
            end: kjvaOrdinalEnd
        ),
        let sourceBookInitials = ordinalTrust.sourceBookInitials,
        let sourceVersification = ordinalTrust.sourceVersification,
        let sourceOrdinalStart = ordinalTrust.sourceOrdinalStart,
        let sourceOrdinalEnd = ordinalTrust.sourceOrdinalEnd,
        let sourceStart = Self.sourceReference(
            forSourceOrdinal: sourceOrdinalStart,
            sourceVersification: sourceVersification
        ),
        let sourceEnd = Self.sourceReference(
            forSourceOrdinal: sourceOrdinalEnd,
            sourceVersification: sourceVersification
        ),
        let verified = Self(
            sourceBookInitials: sourceBookInitials,
            sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd,
            sourceReferenceStart: sourceStart,
            sourceReferenceEnd: sourceEnd
        ),
        verified.kjvaOrdinalStart == kjvaOrdinalStart,
        verified.kjvaOrdinalEnd == kjvaOrdinalEnd else {
            return nil
        }
        self = verified
    }

    /**
     Derives one exactly reversible KJVA subset with row-specific source coordinates.

     - Parameters:
       - kjvaOrdinalStart: Requested inclusive subset start inside this range.
       - kjvaOrdinalEnd: Requested inclusive subset end inside this range.
     - Returns: A verified subset only when strict reverse conversion and forward remapping both
       reproduce the requested endpoints exactly.
     - Side effects: Reads the bundled pinned JSword canon and mapping resources.
     - Failure modes: Out-of-range, fallback-only, many-to-one, or otherwise non-invertible
       endpoints return `nil` so callers can keep the original row unchanged.
     */
    func exactSubrange(
        kjvaOrdinalStart: Int,
        kjvaOrdinalEnd: Int
    ) -> VerifiedKJVAOrdinalRange? {
        guard kjvaOrdinalStart >= self.kjvaOrdinalStart,
              kjvaOrdinalEnd <= self.kjvaOrdinalEnd,
              kjvaOrdinalEnd >= kjvaOrdinalStart,
              let sourceBookInitials = ordinalTrust.sourceBookInitials,
              let sourceVersification = ordinalTrust.sourceVersification,
              let originalSourceStart = ordinalTrust.sourceOrdinalStart,
              let originalSourceEnd = ordinalTrust.sourceOrdinalEnd,
              let sourceStart = Self.sourceReference(
                  forKJVAOrdinal: kjvaOrdinalStart,
                  sourceVersification: sourceVersification
              ),
              let sourceEnd = Self.sourceReference(
                  forKJVAOrdinal: kjvaOrdinalEnd,
                  sourceVersification: sourceVersification
              ),
              sourceStart.ordinal >= originalSourceStart,
              sourceEnd.ordinal <= originalSourceEnd,
              let result = Self(
                  sourceBookInitials: sourceBookInitials,
                  sourceVersification: sourceVersification,
                  sourceOrdinalStart: sourceStart.ordinal,
                  sourceOrdinalEnd: sourceEnd.ordinal,
                  sourceReferenceStart: sourceStart,
                  sourceReferenceEnd: sourceEnd
              ),
              result.kjvaOrdinalStart == kjvaOrdinalStart,
              result.kjvaOrdinalEnd == kjvaOrdinalEnd else {
            return nil
        }
        return result
    }

    /**
     Reconstructs one exact source reference from a retained source ordinal.

     - Parameters:
       - sourceOrdinal: Intro-inclusive source canon ordinal.
       - sourceVersification: Known JSword source versification.
     - Returns: Exact source reference carrying the same ordinal, or `nil` when unavailable.
     - Side effects: Reads the bundled pinned JSword canon.
     - Failure modes: Invalid ordinals and unsupported versifications return `nil`.
     */
    private static func sourceReference(
        forSourceOrdinal sourceOrdinal: Int,
        sourceVersification: String
    ) -> VerseKeyReference? {
        guard let source = JSwordCanon.reference(
            forIndex: sourceOrdinal,
            versification: sourceVersification
        ) else {
            return nil
        }
        return VerseKeyReference(
            osisBookId: source.osisBookId,
            chapter: source.chapter,
            verse: source.verse,
            ordinal: sourceOrdinal
        )
    }

    /**
     Strictly reverse-projects one KJVA ordinal into an exact source reference.

     - Parameters:
       - kjvaOrdinal: Candidate persisted KJVA ordinal.
       - sourceVersification: Source versification retained by the original write.
     - Returns: Source reference whose strict forward mapping returns `kjvaOrdinal` exactly.
     - Side effects: Reads bundled canon and mapping resources.
     - Failure modes: Introduction gaps, fallback-only conversions, and non-round-tripping mappings
       return `nil`.
     */
    private static func sourceReference(
        forKJVAOrdinal kjvaOrdinal: Int,
        sourceVersification: String
    ) -> VerseKeyReference? {
        guard let kjva = JSwordKJVAVersification.referenceIncludingIntroductions(
            ordinal: kjvaOrdinal
        ),
        let conversion = VersificationMapper.convertStrictly(
            osisBookId: kjva.osisId,
            chapter: kjva.chapter,
            verse: kjva.verse,
            from: JSwordKJVAVersification.name,
            to: sourceVersification
        ),
        let sourceOrdinal = JSwordCanon.referenceIndex(
            for: conversion.reference,
            versification: sourceVersification
        ) else {
            return nil
        }
        let source = VerseKeyReference(
            osisBookId: conversion.reference.osisBookId,
            chapter: conversion.reference.chapter,
            verse: conversion.reference.verse,
            ordinal: sourceOrdinal
        )
        guard VersificationMapper.kjvaOrdinal(
            for: source,
            sourceVersification: sourceVersification
        ) == kjvaOrdinal else {
            return nil
        }
        return source
    }
}

/**
 Centralizes persisted-ordinal trust creation and fail-closed validation.

 Numeric KJVA bounds are necessary but never sufficient. A consumer may use a row only when its
 durable state, mapping version, provenance, exact source metadata, and KJVA range agree.
 */
public enum PersistedOrdinalTrustPolicy {
    /// Current strict source-to-KJVA mapping contract version.
    public static let currentMappingVersion = 1

    /**
     Builds metadata for a new native write at the strict mapping boundary.

     - Parameters:
       - sourceBookInitials: Module initials that supplied the source ordinals.
       - sourceVersification: SWORD versification owning the source ordinals.
       - sourceOrdinalStart: Original source start ordinal.
       - sourceOrdinalEnd: Original source end ordinal.
       - kjvaOrdinalStart: Strictly mapped KJVA start ordinal.
       - kjvaOrdinalEnd: Strictly mapped KJVA end ordinal.
     - Returns: `verifiedMappingV1` metadata when all source and target metadata is valid; otherwise
       `legacyUnresolved` metadata that preserves the supplied source details.
     - Side effects: Reads the bundled pinned JSword canon registry.
     - Failure modes: Unknown versifications, missing source identity, invalid source ordinals, and
       invalid KJVA ranges fail closed as unresolved metadata.
     */
    static func nativeMappingMetadata(
        sourceBookInitials: String,
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int,
        kjvaOrdinalStart: Int,
        kjvaOrdinalEnd: Int
    ) -> PersistedOrdinalTrustMetadata {
        let initials = normalizedNonempty(sourceBookInitials)
        let versification = normalizedKnownVersification(sourceVersification)
        let hasValidSourceRange = sourceOrdinalStart > 0 && sourceOrdinalEnd >= sourceOrdinalStart
        let state: PersistedOrdinalTrustState = initials != nil &&
            versification != nil &&
            hasValidSourceRange &&
            isValidKJVARange(start: kjvaOrdinalStart, end: kjvaOrdinalEnd)
            ? .verifiedMappingV1
            : .legacyUnresolved

        return PersistedOrdinalTrustMetadata(
            state: state,
            mappingVersion: state.isVerified ? currentMappingVersion : 0,
            provenance: .nativeMapping,
            sourceBookInitials: initials,
            sourceVersification: versification ?? normalizedNonempty(sourceVersification),
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd
        )
    }

    /**
     Builds metadata for KJVA coordinates imported from Android.

     - Parameters:
       - sourceVersification: Android row's source-versification name.
       - sourceOrdinalStart: Android row's source-domain start ordinal.
       - sourceOrdinalEnd: Android row's source-domain end ordinal.
       - kjvaOrdinalStart: Bounds-validated Android KJVA start ordinal.
       - kjvaOrdinalEnd: Bounds-validated Android KJVA end ordinal.
     - Returns: `verifiedAndroid` metadata for a known source versification and valid KJVA range;
       otherwise unresolved metadata retaining the Android provenance.
     - Side effects: Reads the bundled pinned JSword canon registry.
     - Failure modes: Unknown versification names and invalid ranges fail closed as unresolved.
     */
    static func androidImportMetadata(
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int,
        kjvaOrdinalStart: Int,
        kjvaOrdinalEnd: Int
    ) -> PersistedOrdinalTrustMetadata {
        let versification = normalizedKnownVersification(sourceVersification)
        let state: PersistedOrdinalTrustState = versification != nil &&
            sourceOrdinalStart > 0 &&
            sourceOrdinalEnd >= sourceOrdinalStart &&
            isValidKJVARange(start: kjvaOrdinalStart, end: kjvaOrdinalEnd)
            ? .verifiedAndroid
            : .legacyUnresolved
        return PersistedOrdinalTrustMetadata(
            state: state,
            mappingVersion: state.isVerified ? currentMappingVersion : 0,
            provenance: .androidImport,
            sourceBookInitials: nil,
            sourceVersification: versification ?? normalizedNonempty(sourceVersification),
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd
        )
    }

    /**
     Builds pending metadata for a legacy source range whose module may become available later.

     - Parameters:
       - sourceBookInitials: Legacy module initials.
       - sourceOrdinalStart: Preserved legacy start ordinal.
       - sourceOrdinalEnd: Preserved legacy end ordinal.
     - Returns: Pending metadata when module initials are nonempty, otherwise unresolved metadata.
     - Side effects: none.
     - Failure modes: Empty module initials are classified as unresolved because numeric values do
       not establish their source domain.
     */
    public static func legacyMetadata(
        sourceBookInitials: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int
    ) -> PersistedOrdinalTrustMetadata {
        let initials = normalizedNonempty(sourceBookInitials)
        return PersistedOrdinalTrustMetadata(
            state: initials == nil ? .legacyUnresolved : .legacyPendingModule,
            mappingVersion: 0,
            provenance: .unknown,
            sourceBookInitials: initials,
            sourceVersification: nil,
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd
        )
    }

    /**
     Checks whether a persisted KJVA range is safe for rendering, navigation, totals, or export.

     - Parameters:
       - metadata: Durable trust and source metadata stored with the row.
       - start: Persisted KJVA start ordinal.
       - end: Persisted KJVA end ordinal.
     - Returns: `true` only for a complete, internally consistent verified contract.
     - Side effects: Reads the bundled pinned JSword canon registry.
     - Failure modes: Unknown state/provenance combinations and incomplete source metadata return
       `false` without repairing the row.
     */
    public static func isTrustedKJVARange(
        metadata: PersistedOrdinalTrustMetadata,
        start: Int,
        end: Int
    ) -> Bool {
        guard metadata.state.isVerified,
              metadata.mappingVersion == currentMappingVersion,
              isValidKJVARange(start: start, end: end),
              let sourceVersification = metadata.sourceVersification,
              normalizedKnownVersification(sourceVersification) != nil,
              let sourceStart = metadata.sourceOrdinalStart,
              let sourceEnd = metadata.sourceOrdinalEnd,
              sourceStart > 0,
              sourceEnd >= sourceStart else {
            return false
        }

        switch metadata.state {
        case .verifiedAndroid:
            return metadata.provenance == .androidImport
        case .verifiedMappingV1:
            guard metadata.provenance == .nativeMapping || metadata.provenance == .legacyMigration,
                  let sourceBookInitials = metadata.sourceBookInitials,
                  normalizedNonempty(sourceBookInitials) != nil,
                  let sourceStartReference = JSwordCanon.reference(
                      forIndex: sourceStart,
                      versification: sourceVersification
                  ),
                  let sourceEndReference = JSwordCanon.reference(
                      forIndex: sourceEnd,
                      versification: sourceVersification
                  ),
                  let mappedRange = VersificationMapper.kjvaOrdinalRange(
                      start: VerseKeyReference(
                          osisBookId: sourceStartReference.osisBookId,
                          chapter: sourceStartReference.chapter,
                          verse: sourceStartReference.verse,
                          ordinal: sourceStart
                      ),
                      end: VerseKeyReference(
                          osisBookId: sourceEndReference.osisBookId,
                          chapter: sourceEndReference.chapter,
                          verse: sourceEndReference.verse,
                          ordinal: sourceEnd
                      ),
                      sourceVersification: sourceVersification
                  ) else {
                return false
            }
            return mappedRange.lowerBound == start && mappedRange.upperBound == end
        case .legacyPendingModule, .legacyUnresolved:
            return false
        }
    }

    /**
     Checks whether both endpoints fit Android's persisted KJVA ordinal address space.

     - Parameters:
       - start: Candidate inclusive start ordinal.
       - end: Candidate inclusive end ordinal.
     - Returns: `true` when both values are in bounds and ordered.
     - Side effects: none.
     - Failure modes: Invalid values return `false`.
     */
    public static func isValidKJVARange(start: Int, end: Int) -> Bool {
        JSwordKJVAVersification.progressOrdinalRange.contains(start) &&
            JSwordKJVAVersification.progressOrdinalRange.contains(end) &&
            end >= start
    }

    /**
     Derives durable trust for an exact retained subset of an already trusted persisted range.

     Native and migrated rows are re-resolved through both mapping directions so the subset gets
     its own source endpoints. Android progress rows may be subset only when their retained source
     domain is explicitly KJVA identity; Android authority is preserved rather than relabeled as a
     native mapping.

     - Parameters:
       - metadata: Existing complete trust contract for the original persisted range.
       - persistedStart: Original inclusive KJVA start ordinal.
       - persistedEnd: Original inclusive KJVA end ordinal.
       - subsetStart: Requested inclusive retained KJVA start ordinal.
       - subsetEnd: Requested inclusive retained KJVA end ordinal.
     - Returns: Row-specific verified metadata, or `nil` when exact subset provenance cannot be
       proven.
     - Side effects: Reads the bundled pinned canon and mapping resources.
     - Failure modes: Untrusted originals, out-of-range subsets, non-invertible mappings, and
       non-KJVA Android source domains fail closed with `nil`.
     */
    static func trustedSubsetMetadata(
        of metadata: PersistedOrdinalTrustMetadata,
        persistedStart: Int,
        persistedEnd: Int,
        subsetStart: Int,
        subsetEnd: Int
    ) -> PersistedOrdinalTrustMetadata? {
        guard isTrustedKJVARange(
            metadata: metadata,
            start: persistedStart,
            end: persistedEnd
        ),
        subsetStart >= persistedStart,
        subsetEnd <= persistedEnd,
        isValidKJVARange(start: subsetStart, end: subsetEnd) else {
            return nil
        }

        switch metadata.state {
        case .verifiedMappingV1:
            guard let original = VerifiedKJVAOrdinalRange(
                revalidatingKJVAOrdinalStart: persistedStart,
                kjvaOrdinalEnd: persistedEnd,
                ordinalTrust: metadata
            ),
            let subset = original.exactSubrange(
                kjvaOrdinalStart: subsetStart,
                kjvaOrdinalEnd: subsetEnd
            ) else {
                return nil
            }
            return PersistedOrdinalTrustMetadata(
                state: .verifiedMappingV1,
                mappingVersion: currentMappingVersion,
                provenance: metadata.provenance,
                sourceBookInitials: subset.sourceBookInitials,
                sourceVersification: subset.sourceVersification,
                sourceOrdinalStart: subset.sourceOrdinalStart,
                sourceOrdinalEnd: subset.sourceOrdinalEnd
            )
        case .verifiedAndroid:
            guard metadata.provenance == .androidImport,
                  metadata.sourceVersification == JSwordKJVAVersification.name,
                  metadata.sourceOrdinalStart == persistedStart,
                  metadata.sourceOrdinalEnd == persistedEnd else {
                return nil
            }
            let subset = androidImportMetadata(
                sourceVersification: JSwordKJVAVersification.name,
                sourceOrdinalStart: subsetStart,
                sourceOrdinalEnd: subsetEnd,
                kjvaOrdinalStart: subsetStart,
                kjvaOrdinalEnd: subsetEnd
            )
            return isTrustedKJVARange(metadata: subset, start: subsetStart, end: subsetEnd)
                ? subset
                : nil
        case .legacyPendingModule, .legacyUnresolved:
            return nil
        }
    }

    /**
     Normalizes a source-versification identifier only when Android's pinned JSword recognizes it.

     - Parameter rawValue: Raw persisted or module-provided versification name.
     - Returns: Trimmed supported name, or `nil` for missing and unknown names.
     - Side effects: Reads the bundled pinned JSword canon registry.
     - Failure modes: Unknown names return `nil`.
     */
    public static func normalizedKnownVersification(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return VersificationMapper.supports(trimmed) ? trimmed : nil
    }

    /// Trims one required persisted identity and rejects an empty result without side effects.
    private static func normalizedNonempty(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
