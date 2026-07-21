// BibleReaderBookmarkNavigationCoordinator.swift -- Fail-closed exact bookmark planning

import BibleCore
import Foundation
import SwordKit

/**
 Typed reasons that exact bookmark navigation cannot produce a commit plan.

 Every case represents a failed identity or mapping proof. The planner never turns these failures
 into a nearby key, first page, current document, or numerically plausible verse.
 */
enum BibleReaderBookmarkNavigationFailure: Error, Equatable, LocalizedError, Sendable {
    /// No already-selected Bible module was supplied as the navigation destination.
    case destinationBibleUnavailable
    /// The supplied destination has an empty module identity.
    case invalidDestinationBibleIdentity
    /// The supplied destination is not a Bible module.
    case destinationCategoryMismatch(initials: String, actual: ModuleCategory)
    /// The supplied destination uses an empty or unsupported versification.
    case unsupportedDestinationVersification(String)
    /// A non-nil persisted source-module identity is blank.
    case invalidSourceModuleIdentity
    /// No supplied SWORD candidate has the byte-exact persisted source initials.
    case sourceModuleNotFound(String)
    /// Multiple supplied SWORD candidates have the persisted source initials.
    case sourceModuleAmbiguous(String)
    /// The resolved source candidate is not a Bible module.
    case sourceCategoryMismatch(initials: String, actual: ModuleCategory)
    /// The persisted source versification is empty or unsupported.
    case unsupportedSourceVersification(String)
    /// The resolved source candidate does not use the persisted versification exactly.
    case sourceVersificationMismatch(expected: String, actual: String)
    /// The persisted source range has invalid or non-verse endpoints.
    case invalidSourceOrdinalRange(ClosedRange<Int>)
    /// A normal source-canon ordinal is not exactly addressable by the source module.
    case sourceOrdinalIdentityMismatch(Int)
    /// The canonical source range does not equal the persisted OSIS reference byte-for-byte.
    case sourceReferenceMismatch(expected: String, actual: String)
    /// The persisted KJVA range has invalid or non-verse endpoints.
    case invalidKJVAOrdinalRange(ClosedRange<Int>)
    /// The canonical persisted KJVA range does not equal its OSIS reference byte-for-byte.
    case kjvaReferenceMismatch(expected: String, actual: String)
    /// Full strict source mapping does not exactly reproduce the persisted KJVA verse sequence.
    case kjvaMappingMismatch
    /// A persisted KJVA verse has no strict destination-versification mapping.
    case destinationMappingUnavailable(kjvaOrdinal: Int)
    /// The destination module cannot address a strictly mapped reference.
    case destinationOrdinalUnavailable(kjvaOrdinal: Int)
    /// The destination module cannot reverse its ordinal to the same exact mapped reference.
    case destinationOrdinalIdentityMismatch(kjvaOrdinal: Int)
    /// Destination ordinals are not strictly increasing in source order.
    case destinationOrdinalsNotMonotonic(previous: Int, current: Int)
    /// The generic target has blank module initials.
    case invalidGenericModuleIdentity
    /// The generic target has a blank exact key.
    case invalidGenericKey
    /// The optional generic BVA range contains a negative ordinal.
    case invalidGenericOrdinalRange(ClosedRange<Int>)
    /// No candidate in any supplied generic inventory has the exact persisted initials.
    case genericModuleNotFound(String)
    /// Multiple candidates across the supplied generic inventories share the persisted initials.
    case genericModuleAmbiguous(String)
    /// A resolved SWORD candidate cannot own a generic bookmark.
    case unsupportedGenericCategory(initials: String, actual: ModuleCategory)
    /// The exact persisted key is absent or is not a canonical key for the resolved candidate.
    case genericKeyUnavailable(moduleInitials: String, key: String)
    /// The resolved candidate could not prove the exact key because its backend failed or is ambiguous.
    case genericKeyLookupFailed(moduleInitials: String, key: String)
    /// Lookup returned a fragment whose module or key identity differs from the request.
    case genericFragmentIdentityMismatch(moduleInitials: String, key: String)
    /// Lookup returned a malformed negative BVA domain.
    case invalidGenericFragmentOrdinalRange(ClosedRange<Int>)
    /// The optional persisted BVA range is not contained by the exact resolved fragment.
    case genericOrdinalOutsideFragment(
        requested: ClosedRange<Int>,
        available: ClosedRange<Int>
    )

    /**
     Returns an existing localized reader/bookmark message suitable for presentation by the caller.

     - Returns: A localized explanation with a built-in English fallback.
     - Side effects: Reads localization resources only.
     - Failure modes: None; every case maps to a fallback string.
     */
    var errorDescription: String? {
        switch self {
        case .destinationBibleUnavailable:
            return String(
                localized: "picker_no_bible_modules",
                defaultValue: "No Bible modules are installed."
            )
        case .sourceModuleNotFound, .genericModuleNotFound:
            return String(localized: "error_module_not_found", defaultValue: "Module not found")
        case .genericKeyUnavailable:
            return String(
                localized: "error_no_content",
                defaultValue: "No content for selected verse"
            )
        case .invalidSourceOrdinalRange,
             .sourceOrdinalIdentityMismatch,
             .sourceReferenceMismatch,
             .unsupportedSourceVersification,
             .sourceVersificationMismatch,
             .invalidKJVAOrdinalRange,
             .kjvaReferenceMismatch,
             .kjvaMappingMismatch,
             .destinationMappingUnavailable,
             .destinationOrdinalUnavailable,
             .destinationOrdinalIdentityMismatch,
             .destinationOrdinalsNotMonotonic:
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        case .invalidDestinationBibleIdentity,
             .destinationCategoryMismatch,
             .unsupportedDestinationVersification,
             .invalidSourceModuleIdentity,
             .sourceModuleAmbiguous,
             .sourceCategoryMismatch,
             .invalidGenericModuleIdentity,
             .invalidGenericKey,
             .invalidGenericOrdinalRange,
             .genericModuleAmbiguous,
             .unsupportedGenericCategory,
             .genericKeyLookupFailed,
             .genericFragmentIdentityMismatch,
             .invalidGenericFragmentOrdinalRange,
             .genericOrdinalOutsideFragment:
            return String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/**
 Exact book, chapter, and verse coordinates in one named versification domain.

 Inputs are already-decoded canon coordinates. The value produces a canonical OSIS component and
 otherwise has no side effects or failure path. Ordering belongs to the paired domain ordinal, not
 to lexical comparison of these fields.
 */
struct BibleReaderBookmarkNavigationVerseAddress: Equatable, Sendable {
    /// OSIS book identifier.
    let osisBookID: String
    /// One-based chapter number.
    let chapter: Int
    /// One-based normal verse number; zero is retained only while classifying canon structure.
    let verse: Int

    /**
     Formats this coordinate without localization or alias expansion.

     - Returns: Byte-stable `Book.chapter.verse` OSIS text.
     - Side effects: None.
     - Failure modes: None; validation occurs before an address enters a successful plan.
     */
    var osisReference: String { "\(osisBookID).\(chapter).\(verse)" }
}

/**
 One exact verse paired with the ordinal that addresses it in a specific domain.

 The planner emits these values only after forward/reverse identity checks. They are detached,
 deterministic outputs with no cursor, persistence, or rendering behavior.
 */
struct BibleReaderBookmarkNavigationOrdinalVerse: Equatable, Sendable {
    /// Domain-owned ordinal.
    let ordinal: Int
    /// Exact coordinates resolved from that ordinal.
    let reference: BibleReaderBookmarkNavigationVerseAddress
}

/**
 Immutable proof needed to commit one exact Bible bookmark navigation.

 Inputs are all public persisted target fields plus complete validated source, KJVA, and destination
 projections. The output lets the parent controller commit without reinterpreting an ordinal.
 Construction has no side effects and is impossible through the coordinator when any identity,
 range, reference, strict mapping, addressability, or ordering proof fails.
 */
struct BibleReaderBookmarkNavigationBiblePlan: Equatable, Sendable {
    /// Original optional persisted source identity.
    let requestedSourceModuleInitials: String?
    /// Source module actually used to revalidate source ordinals.
    let resolvedSourceModuleInitials: String
    /// Exact source versification.
    let sourceVersification: String
    /// Exact validated persisted source ordinal range.
    let sourceOrdinalRange: ClosedRange<Int>
    /// Exact validated persisted source OSIS reference.
    let sourceOSISReference: String
    /// Every normal source verse inside the persisted source ordinal range.
    let sourceVerses: [BibleReaderBookmarkNavigationOrdinalVerse]
    /// Exact validated persisted KJVA ordinal range.
    let kjvaOrdinalRange: ClosedRange<Int>
    /// Exact validated persisted KJVA OSIS reference.
    let kjvaOSISReference: String
    /// Every normal KJVA verse inside the persisted KJVA ordinal range.
    let kjvaVerses: [BibleReaderBookmarkNavigationOrdinalVerse]
    /// Already-selected destination module to retain while committing.
    let destinationModuleInitials: String
    /// Exact destination versification.
    let destinationVersification: String
    /// Inclusive endpoint range in the destination module's ordinal domain.
    let destinationOrdinalRange: ClosedRange<Int>
    /// Canonical destination OSIS endpoint reference.
    let destinationOSISReference: String
    /// Strict, addressable destination projection for every KJVA verse.
    let destinationVerses: [BibleReaderBookmarkNavigationOrdinalVerse]
}

/**
 Immutable exact generic SWORD fragment selected by a bookmark.

 The input fragment has already passed exact module/category/key and BVA-containment checks. The
 value is detached output for a later controller commit and has no cursor or rendering side effects.
 */
struct BibleReaderBookmarkNavigationSwordPlan: Equatable, Sendable {
    /// Exact owning module initials.
    let moduleInitials: String
    /// Exact owning module category.
    let category: ModuleCategory
    /// Exact persisted entry key.
    let key: String
    /// Optional BVA selection retained only after containment validation.
    let selectedOrdinalRange: ClosedRange<Int>?
    /// Detached exact OSIS fragment returned by SWORD.
    let fragment: SwordRawOSISFragment
}

/**
 Detached My Documents page content used by exact generic bookmark planning.

 Inputs are copied from one strict unique document/page fetch. The snapshot allows a later commit
 without retaining SwiftData models; producing or reading the value performs no writes and cannot
 fail after construction.
 */
struct BibleReaderBookmarkNavigationMyDocumentFragment: Equatable, Sendable {
    /// Stable parent document identifier.
    let documentID: UUID
    /// Stable page identifier.
    let pageID: UUID
    /// Exact Android-style document initials.
    let moduleInitials: String
    /// User-visible document name.
    let documentName: String
    /// Exact parent-scoped page key.
    let key: String
    /// User-visible page title.
    let title: String
    /// Persisted Android content-type raw value.
    let contentTypeRawValue: String
    /// Raw stored page body.
    let rawContent: String
    /// Optional page language.
    let languageCode: String?
    /// Exact generic ordinal domain for a My Documents page.
    let ordinalRange: ClosedRange<Int>
}

/**
 Immutable exact My Documents destination selected by a bookmark.

 The fragment and optional BVA selection have already passed identity and containment validation.
 This detached output has no persistence or rendering behavior and no post-construction failure.
 */
struct BibleReaderBookmarkNavigationMyDocumentPlan: Equatable, Sendable {
    /// Optional BVA selection retained only after containment validation.
    let selectedOrdinalRange: ClosedRange<Int>?
    /// Detached page identity and content.
    let fragment: BibleReaderBookmarkNavigationMyDocumentFragment
}

/**
 Immutable exact EPUB destination selected by a bookmark.

 Inputs identify one immutable installed generation and one canonical numeric persisted key. The
 output is detached commit data; it neither changes EPUB reader state nor falls back after creation.
 */
struct BibleReaderBookmarkNavigationEpubPlan: Equatable, Sendable {
    /// Stable local library identity.
    let identifier: String
    /// Immutable installed generation identity.
    let generationIdentifier: String
    /// Exact Android-style EPUB initials.
    let moduleInitials: String
    /// Package title.
    let title: String
    /// Package language.
    let language: String
    /// Optional BVA selection retained only after containment validation.
    let selectedOrdinalRange: ClosedRange<Int>?
    /// Detached exact indexed page.
    let content: EpubReader.Content
}

/**
 Detached navigation instructions returned to the parent reader controller.

 The plan deliberately has no `apply` method and retains no persistence or rendering callbacks.
 Constructing it is the complete extent of coordinator work; the controller owns the later commit.
 */
enum BibleReaderBookmarkNavigationCommitPlan: Equatable, Sendable {
    /// Strict Bible range projected into the already-selected destination module.
    case bible(BibleReaderBookmarkNavigationBiblePlan)
    /// Exact generic SWORD key and fragment.
    case sword(BibleReaderBookmarkNavigationSwordPlan)
    /// Exact My Documents page snapshot.
    case myDocument(BibleReaderBookmarkNavigationMyDocumentPlan)
    /// Exact EPUB persisted-key content snapshot.
    case epub(BibleReaderBookmarkNavigationEpubPlan)
}

/**
 Read-only SWORD adapter used by the exact bookmark planner.

 Inputs are immutable metadata plus cursor-restoring exact lookup closures. Outputs are copied verse
 or fragment values. Production closures may temporarily move a serialized SWORD cursor but restore
 it before return; invalid or unreadable keys throw and are never replaced with neighboring content.
 */
struct BibleReaderBookmarkNavigationSwordCandidate {
    /// Exact installed module initials.
    let initials: String
    /// Installed module category.
    let category: ModuleCategory
    /// Effective installed module versification.
    let versification: String
    /// Exact reverse ordinal lookup that restores any underlying module cursor.
    let referenceForOrdinal: (Int) -> BibleReaderBookmarkNavigationOrdinalVerse?
    /// Exact forward coordinate lookup that restores any underlying module cursor.
    let ordinalForReference: (BibleReaderBookmarkNavigationVerseAddress) -> Int?
    /// Exact generic-key lookup that restores any underlying module cursor.
    let fragmentForExactKey: (String) throws -> SwordRawOSISFragment

    /**
     Wraps one installed SWORD module with cursor-restoring read operations.

     - Parameter module: Installed module to expose as a navigation candidate.
     - Side effects: Captures the module reference only; no lookup or cursor movement occurs.
     - Failure modes: None during construction; individual exact reads may fail later.
     */
    init(module: SwordModule) {
        initials = module.info.name
        category = module.info.category
        versification = VersificationMapper.versificationName(for: module)
        referenceForOrdinal = { ordinal in
            module.verseReference(ordinal: ordinal).map {
                BibleReaderBookmarkNavigationOrdinalVerse(
                    ordinal: $0.ordinal,
                    reference: .init(
                        osisBookID: $0.osisBookId,
                        chapter: $0.chapter,
                        verse: $0.verse
                    )
                )
            }
        }
        ordinalForReference = { reference in
            module.verseOrdinal(
                osisBookId: reference.osisBookID,
                chapter: reference.chapter,
                verse: reference.verse
            )
        }
        fragmentForExactKey = { try module.rawOSISFragment(forKey: $0) }
    }

    /**
     Wraps one globally resolved SWORD or SQLite Bible for exact bookmark range planning.

     - Parameter source: Installed Bible whose own versification and ordinal domain are authoritative.
     - Side effects: Captures immutable read adapters only; later SWORD reads restore their cursor and
       SQLite address reads use static KJVA coordinates.
     - Failure modes: Generic-key lookup always fails because this adapter represents a Bible only.
     */
    init(source: BibleReaderInstalledScriptureSource) {
        initials = source.info.name
        category = source.info.category
        versification = source.versificationName
        referenceForOrdinal = { ordinal in
            source.verseReference(ordinal: ordinal).map {
                BibleReaderBookmarkNavigationOrdinalVerse(
                    ordinal: $0.ordinal,
                    reference: .init(
                        osisBookID: $0.osisBookId,
                        chapter: $0.chapter,
                        verse: $0.verse
                    )
                )
            }
        }
        ordinalForReference = { reference in
            source.verseOrdinal(
                osisBookId: reference.osisBookID,
                chapter: reference.chapter,
                verse: reference.verse
            )
        }
        fragmentForExactKey = { key in
            throw BibleReaderBookmarkNavigationFailure.unsupportedGenericCategory(
                initials: source.info.name,
                actual: source.info.category
            )
        }
    }

    /**
     Creates a deterministic read-only candidate for focused coordinator tests.

     - Parameters:
       - initials: Exact candidate identity.
       - category: Candidate category.
       - versification: Candidate versification.
       - referenceForOrdinal: Exact reverse ordinal resolver.
       - ordinalForReference: Exact forward coordinate resolver.
       - fragmentForExactKey: Throwing exact generic fragment resolver.
     - Side effects: Stores closures only.
     - Failure modes: Propagated only when a stored lookup closure is invoked.
     */
    init(
        initials: String,
        category: ModuleCategory,
        versification: String,
        referenceForOrdinal: @escaping (Int) -> BibleReaderBookmarkNavigationOrdinalVerse?,
        ordinalForReference: @escaping (BibleReaderBookmarkNavigationVerseAddress) -> Int?,
        fragmentForExactKey: @escaping (String) throws -> SwordRawOSISFragment
    ) {
        self.initials = initials
        self.category = category
        self.versification = versification
        self.referenceForOrdinal = referenceForOrdinal
        self.ordinalForReference = ordinalForReference
        self.fragmentForExactKey = fragmentForExactKey
    }
}

/**
 Read-only My Documents adapter used by the exact bookmark planner.

 Inputs identify one supplied document and a strict parent-scoped page resolver. The output is a
 detached page snapshot. Reads inherit SwiftData context confinement; duplicate, missing, and failed
 fetches throw without saving or mutating models.
 */
struct BibleReaderBookmarkNavigationMyDocumentCandidate {
    /// Stable supplied document identifier.
    let documentID: UUID
    /// Exact Android-style initials.
    let initials: String
    /// Throwing parent-scoped exact page lookup.
    let fragmentForExactKey: (String) throws -> BibleReaderBookmarkNavigationMyDocumentFragment

    /**
     Wraps one supplied My Documents identity and the store that proves global uniqueness.

     - Parameters:
       - document: Candidate document whose identity enters the supplied inventory.
       - store: Store used for strict document/page lookup.
     - Side effects: Captures model identity and the store only; no fetch occurs during construction.
     - Failure modes: The stored lookup throws strict store errors or an identity mismatch later.
     */
    init(document: MyDocument, store: MyDocumentStore) {
        let expectedDocumentID = document.id
        let expectedInitials = document.initials
        documentID = expectedDocumentID
        initials = expectedInitials
        fragmentForExactKey = { key in
            let page = try store.exactPage(bookInitials: expectedInitials, pageKey: key)
            guard let resolvedDocument = page.document,
                  resolvedDocument.id == expectedDocumentID,
                  resolvedDocument.initials == expectedInitials else {
                throw BibleReaderBookmarkNavigationFailure.genericFragmentIdentityMismatch(
                    moduleInitials: expectedInitials,
                    key: key
                )
            }
            return BibleReaderBookmarkNavigationMyDocumentFragment(
                documentID: resolvedDocument.id,
                pageID: page.id,
                moduleInitials: resolvedDocument.initials,
                documentName: resolvedDocument.name,
                key: page.pageKey,
                title: page.title,
                contentTypeRawValue: page.contentTypeRawValue,
                rawContent: page.pageContent?.content ?? "",
                languageCode: page.languageCode,
                ordinalRange: 0...0
            )
        }
    }

    /**
     Creates a deterministic read-only My Documents candidate for focused tests.

     - Parameters:
       - documentID: Stable candidate document identifier.
       - initials: Exact candidate initials.
       - fragmentForExactKey: Throwing exact page resolver.
     - Side effects: Stores values and the resolver only.
     - Failure modes: Propagated only when the resolver is invoked.
     */
    init(
        documentID: UUID,
        initials: String,
        fragmentForExactKey: @escaping (String) throws -> BibleReaderBookmarkNavigationMyDocumentFragment
    ) {
        self.documentID = documentID
        self.initials = initials
        self.fragmentForExactKey = fragmentForExactKey
    }
}

/**
 Read-only EPUB adapter used by the exact bookmark planner.

 Inputs identify one immutable installed generation and its strict numeric-key reader. Outputs are
 detached content rows. SQLite reads are serialized by the owning reader and fail without changing
 current page, library publication, or renderer state.
 */
struct BibleReaderBookmarkNavigationEpubCandidate {
    /// Stable local library identifier.
    let identifier: String
    /// Immutable installed generation identifier.
    let generationIdentifier: String
    /// Exact Android-style module initials.
    let initials: String
    /// Package title.
    let title: String
    /// Package language.
    let language: String
    /// Throwing exact persisted-key lookup.
    let contentForExactPersistedKey: (String) throws -> EpubReader.Content

    /**
     Wraps one immutable EPUB reader generation.

     - Parameter reader: Open reader whose exact persisted-key API backs this candidate.
     - Side effects: Captures the reader only; no index read occurs during construction.
     - Failure modes: The stored lookup propagates typed EPUB lookup failures later.
     */
    init(reader: EpubReader) {
        identifier = reader.identifier
        generationIdentifier = reader.generationIdentifier
        initials = reader.initials
        title = reader.title
        language = reader.language
        contentForExactPersistedKey = { try reader.exactContent(forPersistedKey: $0) }
    }

    /**
     Creates a deterministic read-only EPUB candidate for focused tests.

     - Parameters:
       - identifier: Stable local library identity.
       - generationIdentifier: Immutable generation identity.
       - initials: Exact Android-style module initials.
       - title: Package title.
       - language: Package language.
       - contentForExactPersistedKey: Throwing exact persisted-key resolver.
     - Side effects: Stores values and the resolver only.
     - Failure modes: Propagated only when the resolver is invoked.
     */
    init(
        identifier: String,
        generationIdentifier: String,
        initials: String,
        title: String,
        language: String,
        contentForExactPersistedKey: @escaping (String) throws -> EpubReader.Content
    ) {
        self.identifier = identifier
        self.generationIdentifier = generationIdentifier
        self.initials = initials
        self.title = title
        self.language = language
        self.contentForExactPersistedKey = contentForExactPersistedKey
    }
}

/**
 Complete caller-supplied inventory used for one pure planning attempt.

 The already-selected destination is separate from searchable source/generic candidates so a nil
 source can obey destination-only semantics. Construction preserves duplicates for later ambiguity
 detection, performs no key lookups, and has no persistence or reader-state side effects.
 */
struct BibleReaderBookmarkNavigationInventory {
    /// Already-selected destination Bible; never inferred from the SWORD inventory.
    let destinationBible: BibleReaderBookmarkNavigationSwordCandidate?
    /// Installed SWORD candidates available for exact source/generic identity resolution.
    let swordCandidates: [BibleReaderBookmarkNavigationSwordCandidate]
    /// My Documents candidates available for exact generic identity resolution.
    let myDocumentCandidates: [BibleReaderBookmarkNavigationMyDocumentCandidate]
    /// Open immutable EPUB candidates available for exact generic identity resolution.
    let epubCandidates: [BibleReaderBookmarkNavigationEpubCandidate]

    /**
     Builds a production inventory without performing any key or ordinal lookup.

     - Parameters:
       - destinationBible: Already-selected active Bible module, or `nil` when unavailable.
       - swordModules: Supplied installed SWORD inventory, including any possible source module.
       - myDocuments: Supplied My Documents inventory.
       - myDocumentStore: Store that proves strict document/page identity; when absent, no My
         Documents candidate can be considered authoritative.
       - epubReaders: Supplied open immutable EPUB generations.
     - Side effects: Captures read-only adapters only.
     - Failure modes: None; missing dependencies become absent candidates and fail during planning.
     */
    init(
        destinationBible: SwordModule?,
        swordModules: [SwordModule],
        myDocuments: [MyDocument],
        myDocumentStore: MyDocumentStore?,
        epubReaders: [EpubReader]
    ) {
        self.destinationBible = destinationBible.map(
            BibleReaderBookmarkNavigationSwordCandidate.init(module:)
        )
        swordCandidates = swordModules.map(
            BibleReaderBookmarkNavigationSwordCandidate.init(module:)
        )
        if let myDocumentStore {
            myDocumentCandidates = myDocuments.map {
                BibleReaderBookmarkNavigationMyDocumentCandidate(
                    document: $0,
                    store: myDocumentStore
                )
            }
        } else {
            myDocumentCandidates = []
        }
        epubCandidates = epubReaders.map(
            BibleReaderBookmarkNavigationEpubCandidate.init(reader:)
        )
    }

    /**
     Creates an explicit inventory from read-only candidates for focused tests and composition.

     - Parameters:
       - destinationBible: Already-selected destination candidate.
       - swordCandidates: Exact SWORD inventory.
       - myDocumentCandidates: Exact My Documents inventory.
       - epubCandidates: Exact EPUB inventory.
     - Side effects: None.
     - Failure modes: None; duplicates are intentionally retained for planner validation.
     */
    init(
        destinationBible: BibleReaderBookmarkNavigationSwordCandidate?,
        swordCandidates: [BibleReaderBookmarkNavigationSwordCandidate] = [],
        myDocumentCandidates: [BibleReaderBookmarkNavigationMyDocumentCandidate] = [],
        epubCandidates: [BibleReaderBookmarkNavigationEpubCandidate] = []
    ) {
        self.destinationBible = destinationBible
        self.swordCandidates = swordCandidates
        self.myDocumentCandidates = myDocumentCandidates
        self.epubCandidates = epubCandidates
    }
}

/**
 Strict source-to-KJVA conversion result used by the planner.

 The input conversion must be authoritative rather than fallback. The detached output pairs exact
 KJVA coordinates with their canonical ordinal and has no side effects or post-construction failure.
 */
struct BibleReaderBookmarkNavigationKJVAMapping {
    /// Canonical KJVA ordinal and reference produced by strict conversion.
    let verse: BibleReaderBookmarkNavigationOrdinalVerse
}

/**
 Immutable canon and strict-conversion dependency used by the planner.

 Inputs are named versifications, ordinals, and exact coordinates. Outputs are optional canonical
 references or authoritative conversions. Production operations read pinned resources and return
 `nil` for unsupported or non-strict mapping; injected test operations are deterministic closures.
 */
struct BibleReaderBookmarkNavigationCanon {
    /// Named-versification support check.
    let supportsVersification: (String) -> Bool
    /// Intro-inclusive source-canon ordinal decoder.
    let sourceReference: (Int, String) -> BibleReaderBookmarkNavigationVerseAddress?
    /// Strict source-reference projection into canonical KJVA identity.
    let sourceToKJVA: (
        BibleReaderBookmarkNavigationVerseAddress,
        String
    ) -> BibleReaderBookmarkNavigationKJVAMapping?
    /// Concrete KJVA verse decoder; structural introduction ordinals return `nil`.
    let kjvaVerse: (Int) -> BibleReaderBookmarkNavigationOrdinalVerse?
    /// Strict canonical KJVA projection into a destination versification.
    let kjvaToDestination: (
        BibleReaderBookmarkNavigationVerseAddress,
        String
    ) -> BibleReaderBookmarkNavigationVerseAddress?

    /**
     Live Android-compatible canon and conversion boundary.

     - Side effects: Lazily reads pinned JSword/SWORD versification resources.
     - Failure modes: Every unavailable or non-authoritative conversion returns `nil`.
     */
    static let live = BibleReaderBookmarkNavigationCanon(
        supportsVersification: VersificationMapper.supports,
        sourceReference: { ordinal, versification in
            SwordVersification.reference(forIndex: ordinal, versification: versification).map {
                .init(osisBookID: $0.osisBookId, chapter: $0.chapter, verse: $0.verse)
            }
        },
        sourceToKJVA: { reference, sourceVersification in
            guard let conversion = VersificationMapper.convertStrictly(
                      osisBookId: reference.osisBookID,
                      chapter: reference.chapter,
                      verse: reference.verse,
                      from: sourceVersification,
                      to: JSwordKJVAVersification.name
                  ),
                  let ordinal = JSwordKJVAVersification.verseOrdinal(
                      osisId: conversion.reference.osisBookId,
                      chapter: conversion.reference.chapter,
                      verse: conversion.reference.verse
                  ) else {
                return nil
            }
            return BibleReaderBookmarkNavigationKJVAMapping(
                verse: .init(
                    ordinal: ordinal,
                    reference: .init(
                        osisBookID: conversion.reference.osisBookId,
                        chapter: conversion.reference.chapter,
                        verse: conversion.reference.verse
                    )
                )
            )
        },
        kjvaVerse: { ordinal in
            JSwordKJVAVersification.verseReference(ordinal: ordinal).map {
                .init(
                    ordinal: $0.ordinal,
                    reference: .init(
                        osisBookID: $0.osisId,
                        chapter: $0.chapter,
                        verse: $0.verse
                    )
                )
            }
        },
        kjvaToDestination: { reference, destinationVersification in
            VersificationMapper.convertStrictly(
                osisBookId: reference.osisBookID,
                chapter: reference.chapter,
                verse: reference.verse,
                from: JSwordKJVAVersification.name,
                to: destinationVersification
            ).map {
                .init(
                    osisBookID: $0.reference.osisBookId,
                    chapter: $0.reference.chapter,
                    verse: $0.reference.verse
                )
            }
        }
    )
}

/**
 Plans exact bookmark navigation without mutating reader, persistence, or render state.

 The coordinator consumes one already-resolved target and an explicit candidate inventory. It
 reconstructs every identity and every normal verse in Bible ranges, or resolves one exact generic
 key after proving cross-inventory uniqueness. Success returns detached immutable commit data only.
 */
struct BibleReaderBookmarkNavigationCoordinator {
    /// Immutable canon/conversion implementation.
    private let canon: BibleReaderBookmarkNavigationCanon

    /**
     Creates a coordinator backed by pinned Android-compatible versification resources.

     - Side effects: None; canon resources are read lazily during planning.
     - Failure modes: None during construction.
     */
    init() {
        canon = .live
    }

    /**
     Creates a coordinator with deterministic strict mapping dependencies for focused tests.

     - Parameter canon: Read-only canon and conversion boundary.
     - Side effects: Stores the dependency only.
     - Failure modes: None during construction.
     */
    init(canon: BibleReaderBookmarkNavigationCanon) {
        self.canon = canon
    }

    /**
     Produces an immutable commit plan only after all target fields are independently revalidated.

     - Parameters:
       - target: Exact bookmark target emitted by BibleCore.
       - inventory: Explicit already-selected destination and candidate inventories.
     - Returns: Detached Bible, SWORD, My Documents, or EPUB commit instructions.
     - Side effects: Performs read-only lookups. SWORD adapters restore cursors; no controller,
       PageManager, persistence, or render callback is retained or invoked.
     - Throws: `BibleReaderBookmarkNavigationFailure` for every unresolved, ambiguous, mismatched,
       non-strict, non-addressable, or out-of-fragment target.
     */
    func plan(
        target: BookmarkNavigationTarget,
        inventory: BibleReaderBookmarkNavigationInventory
    ) throws -> BibleReaderBookmarkNavigationCommitPlan {
        switch target {
        case .bible(let bibleTarget):
            return .bible(try planBible(target: bibleTarget, inventory: inventory))
        case .generic(let genericTarget):
            return try planGeneric(target: genericTarget, inventory: inventory)
        }
    }

    /**
     Revalidates every Bible field and constructs full source/KJVA/destination verse proofs.

     - Parameters:
       - target: Persisted source and KJVA identities to revalidate exactly.
       - inventory: Already-selected destination and exact source candidates.
     - Returns: Detached complete Bible commit proof.
     - Side effects: Performs canon reads and cursor-restoring SWORD lookups only.
     - Throws: A typed failure at the first invalid identity, range, reference, mapping, reverse
       lookup, addressability, or monotonicity boundary.
     */
    private func planBible(
        target: BibleBookmarkNavigationTarget,
        inventory: BibleReaderBookmarkNavigationInventory
    ) throws -> BibleReaderBookmarkNavigationBiblePlan {
        let destination = try validatedDestination(from: inventory)
        let sourceVersification = target.sourceVersification
        guard !sourceVersification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              canon.supportsVersification(sourceVersification) else {
            throw BibleReaderBookmarkNavigationFailure.unsupportedSourceVersification(
                sourceVersification
            )
        }
        let source = try resolvedSource(
            initials: target.sourceModuleInitials,
            destination: destination,
            inventory: inventory
        )
        guard source.category == .bible else {
            throw BibleReaderBookmarkNavigationFailure.sourceCategoryMismatch(
                initials: source.initials,
                actual: source.category
            )
        }
        guard source.versification == sourceVersification else {
            throw BibleReaderBookmarkNavigationFailure.sourceVersificationMismatch(
                expected: sourceVersification,
                actual: source.versification
            )
        }

        let sourceVerses = try validatedSourceVerses(
            range: target.sourceOrdinalRange,
            versification: sourceVersification,
            source: source
        )
        let canonicalSourceReference = Self.rangeReference(sourceVerses)
        guard canonicalSourceReference == target.sourceOSISReference else {
            throw BibleReaderBookmarkNavigationFailure.sourceReferenceMismatch(
                expected: canonicalSourceReference,
                actual: target.sourceOSISReference
            )
        }

        let persistedKJVAVerses = try validatedKJVAVerses(range: target.kjvaOrdinalRange)
        let canonicalKJVAReference = Self.rangeReference(persistedKJVAVerses)
        guard canonicalKJVAReference == target.kjvaOSISReference else {
            throw BibleReaderBookmarkNavigationFailure.kjvaReferenceMismatch(
                expected: canonicalKJVAReference,
                actual: target.kjvaOSISReference
            )
        }

        let mappedKJVAVerses = try sourceVerses.map { sourceVerse in
            guard let mapping = canon.sourceToKJVA(
                      sourceVerse.reference,
                      sourceVersification
                  ),
                  canon.kjvaVerse(mapping.verse.ordinal) == mapping.verse else {
                throw BibleReaderBookmarkNavigationFailure.kjvaMappingMismatch
            }
            return mapping.verse
        }
        guard mappedKJVAVerses == persistedKJVAVerses else {
            throw BibleReaderBookmarkNavigationFailure.kjvaMappingMismatch
        }

        let destinationVerses = try mappedKJVAVerses.reduce(
            into: [BibleReaderBookmarkNavigationOrdinalVerse]()
        ) { result, kjvaVerse in
            guard let destinationReference = canon.kjvaToDestination(
                kjvaVerse.reference,
                destination.versification
            ) else {
                throw BibleReaderBookmarkNavigationFailure.destinationMappingUnavailable(
                    kjvaOrdinal: kjvaVerse.ordinal
                )
            }
            guard let destinationOrdinal = destination.ordinalForReference(destinationReference),
                  destinationOrdinal > 0 else {
                throw BibleReaderBookmarkNavigationFailure.destinationOrdinalUnavailable(
                    kjvaOrdinal: kjvaVerse.ordinal
                )
            }
            let projected = BibleReaderBookmarkNavigationOrdinalVerse(
                ordinal: destinationOrdinal,
                reference: destinationReference
            )
            guard destination.referenceForOrdinal(destinationOrdinal) == projected else {
                throw BibleReaderBookmarkNavigationFailure.destinationOrdinalIdentityMismatch(
                    kjvaOrdinal: kjvaVerse.ordinal
                )
            }
            if let previous = result.last?.ordinal, destinationOrdinal <= previous {
                throw BibleReaderBookmarkNavigationFailure.destinationOrdinalsNotMonotonic(
                    previous: previous,
                    current: destinationOrdinal
                )
            }
            result.append(projected)
        }
        guard let destinationStart = destinationVerses.first,
              let destinationEnd = destinationVerses.last else {
            throw BibleReaderBookmarkNavigationFailure.kjvaMappingMismatch
        }

        return BibleReaderBookmarkNavigationBiblePlan(
            requestedSourceModuleInitials: target.sourceModuleInitials,
            resolvedSourceModuleInitials: source.initials,
            sourceVersification: sourceVersification,
            sourceOrdinalRange: target.sourceOrdinalRange,
            sourceOSISReference: target.sourceOSISReference,
            sourceVerses: sourceVerses,
            kjvaOrdinalRange: target.kjvaOrdinalRange,
            kjvaOSISReference: target.kjvaOSISReference,
            kjvaVerses: persistedKJVAVerses,
            destinationModuleInitials: destination.initials,
            destinationVersification: destination.versification,
            destinationOrdinalRange: destinationStart.ordinal...destinationEnd.ordinal,
            destinationOSISReference: Self.rangeReference(destinationVerses),
            destinationVerses: destinationVerses
        )
    }

    /**
     Resolves one generic candidate across every supplied inventory before exact-key lookup.

     - Parameters:
       - target: Exact module initials, key, and optional BVA selection.
       - inventory: SWORD, My Documents, and EPUB candidates to count before reading.
     - Returns: Backend-specific detached commit data.
     - Side effects: Performs exactly one backend read after uniqueness and category validation.
     - Throws: A typed identity, ambiguity, category, key, fragment, or containment failure.
     */
    private func planGeneric(
        target: GenericBookmarkNavigationTarget,
        inventory: BibleReaderBookmarkNavigationInventory
    ) throws -> BibleReaderBookmarkNavigationCommitPlan {
        guard !target.moduleInitials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.invalidGenericModuleIdentity
        }
        guard !target.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.invalidGenericKey
        }
        if let range = target.ordinalRange, range.lowerBound < 0 {
            throw BibleReaderBookmarkNavigationFailure.invalidGenericOrdinalRange(range)
        }

        let matches = genericCandidates(initials: target.moduleInitials, inventory: inventory)
        guard !matches.isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.genericModuleNotFound(target.moduleInitials)
        }
        guard matches.count == 1, let candidate = matches.first else {
            throw BibleReaderBookmarkNavigationFailure.genericModuleAmbiguous(target.moduleInitials)
        }

        switch candidate {
        case .sword(let sword):
            guard Self.genericSwordCategories.contains(sword.category) else {
                throw BibleReaderBookmarkNavigationFailure.unsupportedGenericCategory(
                    initials: sword.initials,
                    actual: sword.category
                )
            }
            let fragment: SwordRawOSISFragment
            do {
                fragment = try sword.fragmentForExactKey(target.key)
            } catch {
                throw genericLookupFailure(
                    error,
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            guard fragment.source.initials == target.moduleInitials,
                  fragment.source.category == sword.category,
                  fragment.key == target.key else {
                throw BibleReaderBookmarkNavigationFailure.genericFragmentIdentityMismatch(
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            try validateGenericRange(target.ordinalRange, available: fragment.contentOrdinalRange)
            return .sword(.init(
                moduleInitials: target.moduleInitials,
                category: sword.category,
                key: target.key,
                selectedOrdinalRange: target.ordinalRange,
                fragment: fragment
            ))

        case .myDocument(let document):
            let fragment: BibleReaderBookmarkNavigationMyDocumentFragment
            do {
                fragment = try document.fragmentForExactKey(target.key)
            } catch {
                throw genericLookupFailure(
                    error,
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            guard fragment.documentID == document.documentID,
                  fragment.moduleInitials == target.moduleInitials,
                  fragment.key == target.key else {
                throw BibleReaderBookmarkNavigationFailure.genericFragmentIdentityMismatch(
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            try validateGenericRange(target.ordinalRange, available: fragment.ordinalRange)
            return .myDocument(.init(
                selectedOrdinalRange: target.ordinalRange,
                fragment: fragment
            ))

        case .epub(let epub):
            let content: EpubReader.Content
            do {
                content = try epub.contentForExactPersistedKey(target.key)
            } catch {
                throw genericLookupFailure(
                    error,
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            guard epub.initials == target.moduleInitials,
                  content.key == target.key,
                  content.persistedKey == target.key else {
                throw BibleReaderBookmarkNavigationFailure.genericFragmentIdentityMismatch(
                    moduleInitials: target.moduleInitials,
                    key: target.key
                )
            }
            try validateGenericRange(target.ordinalRange, available: content.ordinalRange)
            return .epub(.init(
                identifier: epub.identifier,
                generationIdentifier: epub.generationIdentifier,
                moduleInitials: epub.initials,
                title: epub.title,
                language: epub.language,
                selectedOrdinalRange: target.ordinalRange,
                content: content
            ))
        }
    }

    /**
     Validates the already-selected destination without searching for a substitute.

     - Parameter inventory: Inventory whose dedicated destination slot is authoritative.
     - Returns: The supplied non-empty supported Bible candidate.
     - Side effects: Reads metadata and the versification support registry only.
     - Throws: A typed missing, identity, category, or versification failure.
     */
    private func validatedDestination(
        from inventory: BibleReaderBookmarkNavigationInventory
    ) throws -> BibleReaderBookmarkNavigationSwordCandidate {
        guard let destination = inventory.destinationBible else {
            throw BibleReaderBookmarkNavigationFailure.destinationBibleUnavailable
        }
        guard !destination.initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.invalidDestinationBibleIdentity
        }
        guard destination.category == .bible else {
            throw BibleReaderBookmarkNavigationFailure.destinationCategoryMismatch(
                initials: destination.initials,
                actual: destination.category
            )
        }
        guard !destination.versification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              canon.supportsVersification(destination.versification) else {
            throw BibleReaderBookmarkNavigationFailure.unsupportedDestinationVersification(
                destination.versification
            )
        }
        return destination
    }

    /**
     Resolves a non-nil source exactly, while nil source identity uses only the destination.

     - Parameters:
       - initials: Optional byte-exact persisted source initials.
       - destination: Already-validated selected destination.
       - inventory: SWORD candidates available for explicit-source resolution.
     - Returns: The destination for nil identity, otherwise the sole exact SWORD candidate.
     - Side effects: None; only in-memory identity counting occurs.
     - Throws: A typed blank, missing, or duplicate source-identity failure.
     */
    private func resolvedSource(
        initials: String?,
        destination: BibleReaderBookmarkNavigationSwordCandidate,
        inventory: BibleReaderBookmarkNavigationInventory
    ) throws -> BibleReaderBookmarkNavigationSwordCandidate {
        guard let initials else { return destination }
        guard !initials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.invalidSourceModuleIdentity
        }
        let matches = inventory.swordCandidates.filter { $0.initials == initials }
        guard !matches.isEmpty else {
            throw BibleReaderBookmarkNavigationFailure.sourceModuleNotFound(initials)
        }
        guard matches.count == 1, let source = matches.first else {
            throw BibleReaderBookmarkNavigationFailure.sourceModuleAmbiguous(initials)
        }
        return source
    }

    /**
     Reconstructs every normal source verse and proves exact module ordinal identity.

     - Parameters:
       - range: Persisted inclusive source ordinal range with normal verse endpoints.
       - versification: Exact source canon name.
       - source: Source module candidate whose forward and reverse lookups must agree with the canon.
     - Returns: Every normal verse in ordinal order; structural heading and intro slots are omitted.
     - Side effects: Reads the canon and performs cursor-restoring source-module lookups.
     - Throws: A typed invalid-range or source ordinal/reference identity failure.
     - Complexity: Linear in the inclusive source ordinal span.
     */
    private func validatedSourceVerses(
        range: ClosedRange<Int>,
        versification: String,
        source: BibleReaderBookmarkNavigationSwordCandidate
    ) throws -> [BibleReaderBookmarkNavigationOrdinalVerse] {
        guard range.lowerBound > 0,
              let first = canon.sourceReference(range.lowerBound, versification),
              first.chapter > 0,
              first.verse > 0,
              let last = canon.sourceReference(range.upperBound, versification),
              last.chapter > 0,
              last.verse > 0 else {
            throw BibleReaderBookmarkNavigationFailure.invalidSourceOrdinalRange(range)
        }

        var verses: [BibleReaderBookmarkNavigationOrdinalVerse] = []
        for ordinal in range {
            guard let canonical = canon.sourceReference(ordinal, versification) else { continue }
            guard canonical.chapter > 0, canonical.verse >= 0 else {
                throw BibleReaderBookmarkNavigationFailure.invalidSourceOrdinalRange(range)
            }
            guard canonical.verse > 0 else { continue }
            let expected = BibleReaderBookmarkNavigationOrdinalVerse(
                ordinal: ordinal,
                reference: canonical
            )
            guard source.referenceForOrdinal(ordinal) == expected,
                  source.ordinalForReference(canonical) == ordinal else {
                throw BibleReaderBookmarkNavigationFailure.sourceOrdinalIdentityMismatch(ordinal)
            }
            verses.append(expected)
        }
        guard verses.first?.ordinal == range.lowerBound,
              verses.last?.ordinal == range.upperBound else {
            throw BibleReaderBookmarkNavigationFailure.invalidSourceOrdinalRange(range)
        }
        return verses
    }

    /**
     Reconstructs every concrete persisted KJVA verse while skipping structural intro slots.

     - Parameter range: Persisted inclusive KJVA range with normal verse endpoints.
     - Returns: Every concrete KJVA verse and its exact persisted ordinal in ascending order.
     - Side effects: Reads the pinned KJVA canon only.
     - Throws: `invalidKJVAOrdinalRange` when either endpoint is not a concrete verse.
     - Complexity: Linear in the inclusive KJVA ordinal span.
     */
    private func validatedKJVAVerses(
        range: ClosedRange<Int>
    ) throws -> [BibleReaderBookmarkNavigationOrdinalVerse] {
        guard range.lowerBound > 0,
              canon.kjvaVerse(range.lowerBound)?.ordinal == range.lowerBound,
              canon.kjvaVerse(range.upperBound)?.ordinal == range.upperBound else {
            throw BibleReaderBookmarkNavigationFailure.invalidKJVAOrdinalRange(range)
        }
        let verses = range.compactMap { ordinal -> BibleReaderBookmarkNavigationOrdinalVerse? in
            guard let verse = canon.kjvaVerse(ordinal), verse.ordinal == ordinal else { return nil }
            return verse
        }
        guard verses.first?.ordinal == range.lowerBound,
              verses.last?.ordinal == range.upperBound else {
            throw BibleReaderBookmarkNavigationFailure.invalidKJVAOrdinalRange(range)
        }
        return verses
    }

    /**
     Produces the exact endpoint OSIS string for a non-empty ordered verse sequence.

     - Parameter verses: Canonically ordered verse proof array.
     - Returns: One OSIS reference for a singleton, an endpoint range for multiple verses, or an
       empty string for an impossible empty proof.
     - Side effects: None.
     - Failure modes: Empty input returns an empty sentinel that cannot match a valid target.
     */
    private static func rangeReference(
        _ verses: [BibleReaderBookmarkNavigationOrdinalVerse]
    ) -> String {
        guard let first = verses.first, let last = verses.last else { return "" }
        return first == last
            ? first.reference.osisReference
            : "\(first.reference.osisReference)-\(last.reference.osisReference)"
    }

    /**
     Enumerates byte-exact generic identity matches across all supplied backend inventories.

     - Parameters:
       - initials: Persisted identity to compare without normalization.
       - inventory: Complete SWORD, My Documents, and EPUB candidate inventories.
     - Returns: Every exact match, retaining duplicates and backend provenance.
     - Side effects: None; no key lookup closure is invoked.
     - Failure modes: None; zero and multiple results are validated by the caller.
     */
    private func genericCandidates(
        initials: String,
        inventory: BibleReaderBookmarkNavigationInventory
    ) -> [GenericCandidate] {
        inventory.swordCandidates
            .filter { $0.initials == initials }
            .map(GenericCandidate.sword)
            + inventory.myDocumentCandidates
                .filter { $0.initials == initials }
                .map(GenericCandidate.myDocument)
            + inventory.epubCandidates
                .filter { $0.initials == initials }
                .map(GenericCandidate.epub)
    }

    /**
     Validates a fragment domain and optional contained selection, including ordinal zero.

     - Parameters:
       - requested: Optional persisted inclusive BVA selection.
       - available: Exact resolved fragment BVA domain.
     - Side effects: None.
     - Throws: A typed malformed-fragment or out-of-fragment selection failure.
     */
    private func validateGenericRange(
        _ requested: ClosedRange<Int>?,
        available: ClosedRange<Int>
    ) throws {
        guard available.lowerBound >= 0 else {
            throw BibleReaderBookmarkNavigationFailure.invalidGenericFragmentOrdinalRange(
                available
            )
        }
        guard let requested else { return }
        guard available.contains(requested.lowerBound),
              available.contains(requested.upperBound) else {
            throw BibleReaderBookmarkNavigationFailure.genericOrdinalOutsideFragment(
                requested: requested,
                available: available
            )
        }
    }

    /**
     Maps backend-specific strict lookup errors into stable coordinator failures.

     - Parameters:
       - error: Typed SWORD, My Documents, EPUB, or injected lookup error.
       - moduleInitials: Exact requested module identity retained in the public failure.
       - key: Exact requested persisted key retained in the public failure.
     - Returns: Stable absent-key or failed/ambiguous-read coordinator failure.
     - Side effects: None.
     - Failure modes: Unknown backend errors map conservatively to `genericKeyLookupFailed`.
     */
    private func genericLookupFailure(
        _ error: Error,
        moduleInitials: String,
        key: String
    ) -> BibleReaderBookmarkNavigationFailure {
        if let failure = error as? BibleReaderBookmarkNavigationFailure {
            return failure
        }
        if let failure = error as? SwordRawOSISFragmentError {
            switch failure {
            case .invalidKey, .keyNotFound:
                return .genericKeyUnavailable(moduleInitials: moduleInitials, key: key)
            case .unsupportedCategory, .malformedOSIS:
                return .genericKeyLookupFailed(moduleInitials: moduleInitials, key: key)
            }
        }
        if let failure = error as? MyDocumentExactLookupError {
            switch failure {
            case .invalidDocumentInitials, .documentNotFound, .pageNotFound:
                return .genericKeyUnavailable(moduleInitials: moduleInitials, key: key)
            case .duplicateDocuments,
                 .documentReadFailed,
                 .duplicatePages,
                 .pageReadFailed:
                return .genericKeyLookupFailed(moduleInitials: moduleInitials, key: key)
            }
        }
        if let failure = error as? EpubPersistedKeyLookupError {
            switch failure {
            case .invalidPersistedKey, .contentNotFound:
                return .genericKeyUnavailable(moduleInitials: moduleInitials, key: key)
            case .indexReadFailed:
                return .genericKeyLookupFailed(moduleInitials: moduleInitials, key: key)
            }
        }
        return .genericKeyLookupFailed(moduleInitials: moduleInitials, key: key)
    }

    /**
     Generic SWORD categories backed by the exact raw-OSIS fragment contract.

     Membership is deterministic and immutable. Reading this set has no side effects or failure
     path; Bible, add-on, and unknown categories remain excluded.
     */
    private static let genericSwordCategories: Set<ModuleCategory> = [
        .commentary,
        .dictionary,
        .generalBook,
        .map,
        .dailyDevotion,
        .glossary,
    ]

    /**
     One backend candidate selected only after cross-inventory identity counting.

     Inputs retain backend-specific read adapters; output dispatches exactly one strict lookup.
     The enum performs no work itself and preserves duplicate candidates until validation finishes.
     */
    private enum GenericCandidate {
        /// Exact SWORD candidate.
        case sword(BibleReaderBookmarkNavigationSwordCandidate)
        /// Exact My Documents candidate.
        case myDocument(BibleReaderBookmarkNavigationMyDocumentCandidate)
        /// Exact EPUB candidate.
        case epub(BibleReaderBookmarkNavigationEpubCandidate)
    }
}
