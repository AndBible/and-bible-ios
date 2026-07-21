// BookmarkNavigationTarget.swift -- Exact bookmark navigation contracts

import Foundation
import SwordKit

/**
 Describes an exact destination selected from the bookmark list.

 Android keeps Bible and generic bookmark destinations as distinct result payloads. Bible targets
 carry both source-module coordinates and KJVA interoperability coordinates, while generic targets
 retain the owning module, key, and optional ordinal range. Keeping that distinction in one typed
 contract prevents list code from fabricating a chapter or dropping a generic bookmark target.
 */
public enum BookmarkNavigationTarget: Equatable, Sendable {
    /// Exact Bible range with source and Android KJVA identity.
    case bible(BibleBookmarkNavigationTarget)

    /// Exact key in a non-Bible module.
    case generic(GenericBookmarkNavigationTarget)
}

/**
 Exact Bible bookmark destination emitted to the reader.

 The KJVA OSIS range is suitable for Android-compatible history and cross-module conversion. The
 source fields let the reader prefer the original module and versification when it is installed.
 Callers must map these coordinates strictly into the active module; none of the ordinal fields may
 be reinterpreted in a different versification.
 */
public struct BibleBookmarkNavigationTarget: Equatable, Sendable {
    /// Module initials that owned the source ordinals, or `nil` for module-neutral Android rows.
    public let sourceModuleInitials: String?

    /// Versification that owns `sourceOrdinalRange`.
    public let sourceVersification: String

    /// Inclusive range in the source module's ordinal domain.
    public let sourceOrdinalRange: ClosedRange<Int>

    /// Exact OSIS verse or range in `sourceVersification`.
    public let sourceOSISReference: String

    /// Inclusive Android KJVA ordinal range.
    public let kjvaOrdinalRange: ClosedRange<Int>

    /// Exact KJVA OSIS reference or range, such as `John.3.16-John.3.18`.
    public let kjvaOSISReference: String

    /**
     Creates one already-validated Bible destination.

     - Parameters:
       - sourceModuleInitials: Optional source module initials.
       - sourceVersification: Versification owning the source ordinals.
       - sourceOrdinalRange: Inclusive source ordinal range.
       - sourceOSISReference: Exact source-versification OSIS reference or range.
       - kjvaOrdinalRange: Inclusive Android KJVA ordinal range.
       - kjvaOSISReference: Exact KJVA OSIS reference or range.
     - Side effects: None.
     - Failure modes: Validation belongs to `BookmarkNavigationTargetResolver`.
     */
    public init(
        sourceModuleInitials: String?,
        sourceVersification: String,
        sourceOrdinalRange: ClosedRange<Int>,
        sourceOSISReference: String,
        kjvaOrdinalRange: ClosedRange<Int>,
        kjvaOSISReference: String
    ) {
        self.sourceModuleInitials = sourceModuleInitials
        self.sourceVersification = sourceVersification
        self.sourceOrdinalRange = sourceOrdinalRange
        self.sourceOSISReference = sourceOSISReference
        self.kjvaOrdinalRange = kjvaOrdinalRange
        self.kjvaOSISReference = kjvaOSISReference
    }
}

/**
 Exact generic bookmark destination emitted to the reader.

 Generic keys are meaningful only inside their owning module. The optional ordinal range is retained
 for modules whose key lookup also exposes stable ordinals, but consumers must never substitute it
 for a failed key lookup.
 */
public struct GenericBookmarkNavigationTarget: Equatable, Sendable {
    /// Owning dictionary, commentary, map, EPUB, or general-book module initials.
    public let moduleInitials: String

    /// Exact persisted module key.
    public let key: String

    /// Optional inclusive ordinal range in that same module.
    public let ordinalRange: ClosedRange<Int>?

    /**
     Creates one already-validated generic destination.

     - Parameters:
       - moduleInitials: Non-empty owning module initials.
       - key: Non-empty exact module key.
       - ordinalRange: Optional range in the owning module.
     - Side effects: None.
     - Failure modes: Validation belongs to `BookmarkNavigationTargetResolver`.
     */
    public init(moduleInitials: String, key: String, ordinalRange: ClosedRange<Int>?) {
        self.moduleInitials = moduleInitials
        self.key = key
        self.ordinalRange = ordinalRange
    }
}

/** Fail-closed reasons that prevent bookmark navigation. */
public enum BookmarkNavigationTargetError: Error, Equatable, LocalizedError, Sendable {
    /// Persisted Bible coordinates have not passed the repository's provenance checks.
    case untrustedBibleOrdinals

    /// Persisted KJVA coordinates do not identify an addressable Bible verse range.
    case invalidBibleOrdinals(start: Int, end: Int)

    /// Source ordinals are missing, non-positive, or reversed.
    case invalidSourceOrdinals(start: Int, end: Int)

    /// The source versification is empty or unsupported by the pinned JSword registry.
    case unsupportedVersification(String)

    /// A generic bookmark has no owning module initials.
    case missingGenericModule

    /// A generic bookmark has no exact key.
    case missingGenericKey

    /// A generic ordinal range is incomplete, negative, or reversed.
    case invalidGenericOrdinals(start: Int?, end: Int?)

    /// User-visible explanation suitable for the bookmark-list error alert.
    public var errorDescription: String? {
        switch self {
        case .untrustedBibleOrdinals,
             .invalidBibleOrdinals,
             .invalidSourceOrdinals,
             .unsupportedVersification,
             .invalidGenericOrdinals:
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        case .missingGenericModule:
            return String(localized: "error_module_not_found", defaultValue: "Module not found")
        case .missingGenericKey:
            return String(
                localized: "error_no_content",
                defaultValue: "No content for selected verse"
            )
        }
    }
}

/**
 Builds exact navigation targets from persisted bookmark rows.

 Resolution validates all coordinates without guessing. In particular, the resolver never applies
 chapter arithmetic to an ordinal, substitutes Genesis, or drops a generic key. It performs no
 persistence or reader navigation.
 */
public enum BookmarkNavigationTargetResolver {
    /**
     Resolves one Bible bookmark into source and KJVA coordinates.

     - Parameter bookmark: Persisted Bible bookmark selected by the user.
     - Returns: Exact typed Bible destination.
     - Side effects: Reads the pinned KJVA canon and versification registry.
     - Throws: `BookmarkNavigationTargetError` when any required coordinate is invalid.
     */
    public static func resolve(_ bookmark: BibleBookmark) throws -> BookmarkNavigationTarget {
        guard bookmark.hasTrustedPersistedOrdinals else {
            throw BookmarkNavigationTargetError.untrustedBibleOrdinals
        }
        let sourceVersification = bookmark.v11n.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceVersification.isEmpty, VersificationMapper.supports(sourceVersification) else {
            throw BookmarkNavigationTargetError.unsupportedVersification(sourceVersification)
        }

        let sourceEnd = bookmark.ordinalEnd > 0 ? bookmark.ordinalEnd : bookmark.ordinalStart
        let trust = bookmark.ordinalTrustMetadata
        guard bookmark.ordinalStart > 0,
              sourceEnd >= bookmark.ordinalStart,
              let trustedVersification = trust.sourceVersification,
              JSwordCanon.normalizedName(trustedVersification)
                  == JSwordCanon.normalizedName(sourceVersification),
              trust.sourceOrdinalStart == bookmark.ordinalStart,
              trust.sourceOrdinalEnd == sourceEnd,
              let sourceStart = JSwordCanon.reference(
                  forIndex: bookmark.ordinalStart,
                  versification: sourceVersification
              ),
              let sourceFinish = JSwordCanon.reference(
                  forIndex: sourceEnd,
                  versification: sourceVersification
              ),
              sourceStart.chapter > 0,
              sourceStart.verse > 0,
              sourceFinish.chapter > 0,
              sourceFinish.verse > 0 else {
            throw BookmarkNavigationTargetError.invalidSourceOrdinals(
                start: bookmark.ordinalStart,
                end: bookmark.ordinalEnd
            )
        }

        let kjvaEnd = bookmark.kjvOrdinalEnd > 0
            ? bookmark.kjvOrdinalEnd
            : bookmark.kjvOrdinalStart
        guard bookmark.kjvOrdinalStart > 0,
              kjvaEnd >= bookmark.kjvOrdinalStart,
              let start = JSwordKJVAVersification.verseReference(
                  ordinal: bookmark.kjvOrdinalStart
              ),
              let end = JSwordKJVAVersification.verseReference(ordinal: kjvaEnd) else {
            throw BookmarkNavigationTargetError.invalidBibleOrdinals(
                start: bookmark.kjvOrdinalStart,
                end: bookmark.kjvOrdinalEnd
            )
        }

        let osisReference = start.ordinal == end.ordinal
            ? start.osisRef
            : "\(start.osisRef)-\(end.osisRef)"
        let sourceStartOSIS = sourceOSISReference(sourceStart)
        let sourceEndOSIS = sourceOSISReference(sourceFinish)
        let sourceOSISReference = sourceStart == sourceFinish
            ? sourceStartOSIS
            : "\(sourceStartOSIS)-\(sourceEndOSIS)"
        let initials = bookmark.bookInitials
        return .bible(BibleBookmarkNavigationTarget(
            sourceModuleInitials: initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : initials,
            sourceVersification: sourceVersification,
            sourceOrdinalRange: bookmark.ordinalStart...sourceEnd,
            sourceOSISReference: sourceOSISReference,
            kjvaOrdinalRange: bookmark.kjvOrdinalStart...kjvaEnd,
            kjvaOSISReference: osisReference
        ))
    }

    /**
     Resolves one generic bookmark without discarding its owning module or key.

     - Parameter bookmark: Persisted generic bookmark selected by the user.
     - Returns: Exact typed generic destination.
     - Side effects: None.
     - Throws: `BookmarkNavigationTargetError` for missing identity or malformed ordinals.
     */
    public static func resolve(_ bookmark: GenericBookmark) throws -> BookmarkNavigationTarget {
        let initials = bookmark.bookInitials
        guard !initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookmarkNavigationTargetError.missingGenericModule
        }
        let key = bookmark.key
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookmarkNavigationTargetError.missingGenericKey
        }

        let ordinalRange: ClosedRange<Int>?
        switch (bookmark.ordinalStart, bookmark.ordinalEnd) {
        case (nil, nil):
            ordinalRange = nil
        case let (start?, nil) where start >= 0:
            ordinalRange = start...start
        case let (start?, end?) where start >= 0 && end >= start:
            ordinalRange = start...end
        default:
            throw BookmarkNavigationTargetError.invalidGenericOrdinals(
                start: bookmark.ordinalStart,
                end: bookmark.ordinalEnd
            )
        }

        return .generic(GenericBookmarkNavigationTarget(
            moduleInitials: initials,
            key: key,
            ordinalRange: ordinalRange
        ))
    }

    /** Formats one validated source-canon coordinate as an OSIS verse reference. */
    private static func sourceOSISReference(_ reference: SwordVersification.Reference) -> String {
        "\(reference.osisBookId).\(reference.chapter).\(reference.verse)"
    }
}
