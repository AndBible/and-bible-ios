import Foundation
import SwordKit

/** Verified source identity and derived lookup fields accepted by Bible bookmark writes only. */
public protocol BibleBookmarkOrdinalRange: Sendable {
    var sourceBookInitials: String { get }
    var sourceVersification: String { get }
    var sourceOrdinalStart: Int { get }
    var sourceOrdinalEnd: Int { get }
    var kjvaOrdinalStart: Int { get }
    var kjvaOrdinalEnd: Int { get }
    var ordinalTrust: PersistedOrdinalTrustMetadata { get }
}

extension VerifiedKJVAOrdinalRange: BibleBookmarkOrdinalRange {}

/**
 Validates original bookmark coordinates and derives Android's independent KJVA lookup span.
 Unlike the strict progress contract, a lookup may be lossy or zero. Source coordinates remain
 authoritative. Construction reads pinned canon resources only and rejects invalid source ranges.
 */
public struct VerifiedBibleBookmarkRange: BibleBookmarkOrdinalRange, Sendable {
    public let sourceBookInitials: String
    public let sourceVersification: String
    public let sourceOrdinalStart: Int
    public let sourceOrdinalEnd: Int
    public let kjvaOrdinalStart: Int
    public let kjvaOrdinalEnd: Int
    public let ordinalTrust: PersistedOrdinalTrustMetadata

    /** Resolves valid source endpoints and computes JSword bookmark lookup indexes without writes. */
    public init?(
        sourceBookInitials: String,
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int
    ) {
        guard !sourceBookInitials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceOrdinalStart > 0, sourceOrdinalEnd >= sourceOrdinalStart,
              let start = JSwordCanon.reference(forIndex: sourceOrdinalStart, versification: sourceVersification),
              let end = JSwordCanon.reference(forIndex: sourceOrdinalEnd, versification: sourceVersification),
              let range = VersificationMapper.androidBookmarkLookupRange(
                start: .init(osisBookId: start.osisBookId, chapter: start.chapter, verse: start.verse, ordinal: sourceOrdinalStart),
                end: .init(osisBookId: end.osisBookId, chapter: end.chapter, verse: end.verse, ordinal: sourceOrdinalEnd),
                sourceVersification: sourceVersification
              ) else { return nil }
        self.sourceBookInitials = sourceBookInitials
        self.sourceVersification = sourceVersification
        self.sourceOrdinalStart = sourceOrdinalStart
        self.sourceOrdinalEnd = sourceOrdinalEnd
        self.kjvaOrdinalStart = range.lowerBound
        self.kjvaOrdinalEnd = range.upperBound
        let strict = VerifiedKJVAOrdinalRange(
            resolvingSourceBookInitials: sourceBookInitials, sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart, sourceOrdinalEnd: sourceOrdinalEnd
        )
        if let strict, strict.kjvaOrdinalStart == range.lowerBound, strict.kjvaOrdinalEnd == range.upperBound {
            self.ordinalTrust = strict.ordinalTrust
        } else {
            self.ordinalTrust = .init(
            state: .verifiedBookmarkProjectionV1, mappingVersion: 1, provenance: .nativeMapping,
            sourceBookInitials: sourceBookInitials, sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart, sourceOrdinalEnd: sourceOrdinalEnd
            )
        }
    }
}

extension VersificationMapper {
    /**
     Derives Android's bookmark lookup span from exact source endpoints, independently of identity.
     JSword retains coordinates on a strict miss, counts past chapter ends, and returns zero for
     absent target books/chapters. Nil means invalid source data; zero is a valid lookup outcome.
     Reads bundled canon data only. Never use this result as authoritative progress coordinates.
     */
    public static func androidBookmarkLookupRange(
        start: VerseKeyReference,
        end: VerseKeyReference,
        sourceVersification: String
    ) -> ClosedRange<Int>? {
        func lookup(_ reference: VerseKeyReference) -> Int? {
            let source = SwordVersification.Reference(osisBookId: reference.osisBookId,
                                                      chapter: reference.chapter, verse: reference.verse)
            guard JSwordCanon.referenceIndex(for: source, versification: sourceVersification) != nil,
                  let converted = convert(reference: reference, from: sourceVersification, to: "KJVA") else { return nil }
            let intro = SwordVersification.Reference(osisBookId: converted.reference.osisBookId,
                                                     chapter: converted.reference.chapter, verse: 0)
            guard let base = JSwordCanon.mappingReferenceIndex(for: intro, versification: "KJVA") else { return 0 }
            let (ordinal, overflow) = base.addingReportingOverflow(converted.reference.verse)
            return overflow ? nil : ordinal
        }
        guard let lower = lookup(start), let upper = lookup(end) else { return nil }
        return min(lower, upper)...max(lower, upper)
    }
}

extension PersistedOrdinalTrustPolicy {
    /**
     Checks bookmark provenance without admitting lookup projections as exact progress coordinates.
     Existing strict/import contracts remain valid. Native bookmark projections must reproduce
     their stored lookup span from retained source metadata. No mutation or guessed identity occurs.
     */
    public static func isTrustedBookmarkRange(
        metadata: PersistedOrdinalTrustMetadata, start: Int, end: Int
    ) -> Bool {
        if isTrustedKJVARange(metadata: metadata, start: start, end: end) { return true }
        guard metadata.state == .verifiedBookmarkProjectionV1, metadata.mappingVersion == 1,
              metadata.provenance == .nativeMapping || metadata.provenance == .androidImport,
              let v11n = metadata.sourceVersification,
              let sourceStart = metadata.sourceOrdinalStart, let sourceEnd = metadata.sourceOrdinalEnd,
              let range = VerifiedBibleBookmarkRange(sourceBookInitials: metadata.sourceBookInitials ?? "Android",
                sourceVersification: v11n, sourceOrdinalStart: sourceStart, sourceOrdinalEnd: sourceEnd)
        else { return false }
        return range.kjvaOrdinalStart == start && range.kjvaOrdinalEnd == end
    }
}

extension PersistedOrdinalTrustPolicy {
    /**
     Admits reproducible Android bookmark projections while retaining the existing import contract
     for ordinary bounded Android rows. Unknown source systems never gain projection provenance.
     No writes occur; callers persist the returned metadata with the unchanged Android fields.
     */
    public static func androidBookmarkImportMetadata(
        sourceVersification: String, sourceOrdinalStart: Int, sourceOrdinalEnd: Int,
        kjvaOrdinalStart: Int, kjvaOrdinalEnd: Int
    ) -> PersistedOrdinalTrustMetadata {
        if let range = VerifiedBibleBookmarkRange(sourceBookInitials: "Android",
            sourceVersification: sourceVersification, sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd),
           range.kjvaOrdinalStart == kjvaOrdinalStart, range.kjvaOrdinalEnd == kjvaOrdinalEnd,
           range.ordinalTrust.state == .verifiedBookmarkProjectionV1 {
            return .init(state: .verifiedBookmarkProjectionV1, mappingVersion: 1, provenance: .androidImport,
                sourceBookInitials: nil, sourceVersification: sourceVersification,
                sourceOrdinalStart: sourceOrdinalStart, sourceOrdinalEnd: sourceOrdinalEnd)
        }
        return androidImportMetadata(sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart, sourceOrdinalEnd: sourceOrdinalEnd,
            kjvaOrdinalStart: kjvaOrdinalStart, kjvaOrdinalEnd: kjvaOrdinalEnd)
    }
}
