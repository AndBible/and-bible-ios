import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/**
 Behavior tests for fail-closed exact bookmark navigation planning.

 Most tests use deterministic in-memory canon and backend adapters and record lookup and forbidden
 commit effects explicitly. One production-adapter test copies the repository KJV fixture into an
 isolated temporary directory and relies on inherited teardown for cleanup; no test touches network,
 persistence, rendering, or shared reader state. Failures indicate a loss of exact identity,
 complete mapping, containment, localization, or pure-planning behavior required for
 Android-compatible bookmark navigation.
 */
final class BibleReaderBookmarkNavigationCoordinatorTests: BibleUISwordFixtureTestCase {
    /**
     Verifies a valid Bible target returns every proven verse without applying the plan.

     Reader, persistence, and rendering counters remain unchanged because the planner accepts no
     commit callbacks. The source and destination proof arrays include the complete two-verse range.
     */
    func testBiblePlanningReturnsCompleteImmutableProjectionWithoutCommitSideEffects() throws {
        let sideEffects = PlanningSideEffectProbe()
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())

        let result = try coordinator.plan(
            target: makeBibleTarget(),
            inventory: makeBibleInventory()
        )

        guard case .bible(let plan) = result else {
            return XCTFail("Expected a Bible commit plan")
        }
        XCTAssertEqual(plan.requestedSourceModuleInitials, "SOURCE")
        XCTAssertEqual(plan.resolvedSourceModuleInitials, "SOURCE")
        XCTAssertEqual(plan.sourceOrdinalRange, 10...11)
        XCTAssertEqual(plan.sourceOSISReference, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(plan.sourceVerses, baseSourceVerses)
        XCTAssertEqual(plan.kjvaOrdinalRange, 100...101)
        XCTAssertEqual(plan.kjvaOSISReference, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(plan.kjvaVerses, baseKJVAVerses)
        XCTAssertEqual(plan.destinationModuleInitials, "DESTINATION")
        XCTAssertEqual(plan.destinationOrdinalRange, 200...201)
        XCTAssertEqual(plan.destinationOSISReference, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(plan.destinationVerses, baseDestinationVerses)
        XCTAssertEqual(sideEffects.readerMutations, 0)
        XCTAssertEqual(sideEffects.persistenceWrites, 0)
        XCTAssertEqual(sideEffects.renderRequests, 0)
    }

    /**
     Verifies the production canon and SWORD adapters preserve the active module cursor.

     An isolated real KJV fixture supplies exact Genesis ordinals, and the production coordinator
     maps them through persisted KJVA identity back into the same selected Bible. A complete plan
     plus byte-equal pre/post module key proves cursor-restoring reads and strict addressability; a
     failure indicates a mismatch between injected-contract tests and the live SwordKit boundary.
     Fixture files are removed by `BibleUISwordFixtureTestCase.tearDown()`.
     */
    func testProductionBiblePlanningMapsEveryLiveVerseWithoutChangingModuleCursor() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let sourceStart = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let sourceEnd = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2)
        )
        let kjvaStart = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 1
        ))
        let kjvaEnd = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: "Gen",
            chapter: 1,
            verse: 2
        ))
        module.setKey("Gen 2:1")
        let initialKey = module.currentKey()
        let target = BookmarkNavigationTarget.bible(.init(
            sourceModuleInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalRange: sourceStart...sourceEnd,
            sourceOSISReference: "Gen.1.1-Gen.1.2",
            kjvaOrdinalRange: kjvaStart...kjvaEnd,
            kjvaOSISReference: "Gen.1.1-Gen.1.2"
        ))
        let inventory = BibleReaderBookmarkNavigationInventory(
            destinationBible: module,
            swordModules: [module],
            myDocuments: [],
            myDocumentStore: nil,
            epubReaders: []
        )

        let result = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )

        guard case .bible(let plan) = result else {
            return XCTFail("Expected a Bible commit plan")
        }
        XCTAssertEqual(plan.sourceVerses.count, 2)
        XCTAssertEqual(plan.kjvaVerses.count, 2)
        XCTAssertEqual(plan.destinationVerses.count, 2)
        XCTAssertEqual(plan.destinationOrdinalRange, sourceStart...sourceEnd)
        XCTAssertEqual(module.currentKey(), initialKey)
    }

    /**
     Verifies a module-neutral Bible target uses only the already-selected destination as source.

     A supplied alternative Bible would also satisfy the versification but must never be consulted;
     its read counter proves nil source identity does not trigger inventory substitution.
     */
    func testNilBibleSourceUsesOnlyAlreadySelectedDestinationWithoutInventoryFallback() throws {
        let ignoredReads = LookupProbe()
        let ignored = BibleReaderBookmarkNavigationSwordCandidate(
            initials: "IGNORED",
            category: .bible,
            versification: "KJV",
            referenceForOrdinal: { ordinal in
                ignoredReads.readCount += 1
                return self.baseSourceVerses.first { $0.ordinal == ordinal }
            },
            ordinalForReference: { _ in nil },
            fragmentForExactKey: { _ in throw StubLookupError.failed }
        )
        let destination = makeSwordCandidate(
            initials: "DESTINATION",
            category: .bible,
            verses: baseSourceVerses
        )
        let inventory = BibleReaderBookmarkNavigationInventory(
            destinationBible: destination,
            swordCandidates: [ignored]
        )
        let target = makeBibleTarget(sourceModuleInitials: nil)

        let result = try BibleReaderBookmarkNavigationCoordinator(canon: makeCanon()).plan(
            target: target,
            inventory: inventory
        )

        guard case .bible(let plan) = result else {
            return XCTFail("Expected a Bible commit plan")
        }
        XCTAssertNil(plan.requestedSourceModuleInitials)
        XCTAssertEqual(plan.resolvedSourceModuleInitials, "DESTINATION")
        XCTAssertEqual(plan.destinationVerses, baseSourceVerses)
        XCTAssertEqual(ignoredReads.readCount, 0)
    }

    /**
     Rejects absent, malformed, non-Bible, and unsupported destination candidates.

     Deterministic metadata-only candidates exercise each destination guard before source lookup.
     Exact typed failures prove the planner never searches installed modules for a replacement; a
     failure would permit navigation away from the caller's already-selected Bible. No state is
     persisted or rendered.
     */
    func testBiblePlanningRejectsEveryInvalidAlreadySelectedDestinationState() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        assertFailure(
            .destinationBibleUnavailable,
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: nil)
        )
        assertFailure(
            .invalidDestinationBibleIdentity,
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: makeSwordCandidate(
                initials: " ",
                category: .bible,
                verses: baseDestinationVerses
            ))
        )
        assertFailure(
            .destinationCategoryMismatch(initials: "DESTINATION", actual: .dictionary),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: makeSwordCandidate(
                initials: "DESTINATION",
                category: .dictionary,
                verses: baseDestinationVerses
            ))
        )
        assertFailure(
            .unsupportedDestinationVersification("Unknown"),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: makeSwordCandidate(
                initials: "DESTINATION",
                category: .bible,
                versification: "Unknown",
                verses: baseDestinationVerses
            ))
        )
    }

    /**
     Rejects every invalid explicit source identity, category, and versification state.

     The fixture varies blank, missing, duplicate, non-Bible, unsupported, and mismatched source
     metadata while retaining a valid destination. Exact failures prove non-nil source initials are
     authoritative; a failure would indicate source substitution or domain relabeling. The test is
     synchronous and performs no external I/O.
     */
    func testBiblePlanningRequiresOneExactBibleSourceWithMatchingVersification() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon(
            supportsVersification: { ["KJV", "NRSV"].contains($0) }
        ))
        let destination = makeSwordCandidate(
            initials: "DESTINATION",
            category: .bible,
            verses: baseDestinationVerses
        )
        assertFailure(
            .invalidSourceModuleIdentity,
            coordinator: coordinator,
            target: makeBibleTarget(sourceModuleInitials: " "),
            inventory: .init(destinationBible: destination)
        )
        assertFailure(
            .sourceModuleNotFound("SOURCE"),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: destination)
        )
        let source = makeSwordCandidate(
            initials: "SOURCE",
            category: .bible,
            verses: baseSourceVerses
        )
        assertFailure(
            .sourceModuleAmbiguous("SOURCE"),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(destinationBible: destination, swordCandidates: [source, source])
        )
        assertFailure(
            .sourceCategoryMismatch(initials: "SOURCE", actual: .dictionary),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(
                destinationBible: destination,
                swordCandidates: [makeSwordCandidate(
                    initials: "SOURCE",
                    category: .dictionary,
                    verses: baseSourceVerses
                )]
            )
        )
        assertFailure(
            .unsupportedSourceVersification("Unknown"),
            coordinator: coordinator,
            target: makeBibleTarget(sourceVersification: "Unknown"),
            inventory: .init(destinationBible: destination, swordCandidates: [source])
        )
        assertFailure(
            .sourceVersificationMismatch(expected: "KJV", actual: "NRSV"),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(
                destinationBible: destination,
                swordCandidates: [makeSwordCandidate(
                    initials: "SOURCE",
                    category: .bible,
                    versification: "NRSV",
                    verses: baseSourceVerses
                )]
            )
        )
    }

    /**
     Rejects malformed source bounds, interior ordinal drift, and exact OSIS reference drift.

     A deterministic two-verse canon isolates endpoint validation, bidirectional module lookup, and
     the persisted source-reference field. Exact errors prove each public field is independently
     checked; a failure would allow numerically plausible but differently addressed source data. No
     shared reader or persistence state is used.
     */
    func testBiblePlanningRevalidatesSourceRangeOrdinalAndReferenceIdentity() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        assertFailure(
            .invalidSourceOrdinalRange(0...0),
            coordinator: coordinator,
            target: makeBibleTarget(sourceOrdinalRange: 0...0, sourceOSISReference: "Gen.1.1"),
            inventory: makeBibleInventory()
        )
        let incompleteSource = makeSwordCandidate(
            initials: "SOURCE",
            category: .bible,
            verses: [baseSourceVerses[0]]
        )
        assertFailure(
            .sourceOrdinalIdentityMismatch(11),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(
                destinationBible: makeSwordCandidate(
                    initials: "DESTINATION",
                    category: .bible,
                    verses: baseDestinationVerses
                ),
                swordCandidates: [incompleteSource]
            )
        )
        let irreversibleSource = makeSwordCandidate(
            initials: "SOURCE",
            category: .bible,
            verses: baseSourceVerses,
            ordinalForReference: { reference in reference.verse == 1 ? 99 : 11 }
        )
        assertFailure(
            .sourceOrdinalIdentityMismatch(10),
            coordinator: coordinator,
            target: makeBibleTarget(),
            inventory: .init(
                destinationBible: makeSwordCandidate(
                    initials: "DESTINATION",
                    category: .bible,
                    verses: baseDestinationVerses
                ),
                swordCandidates: [irreversibleSource]
            )
        )
        assertFailure(
            .sourceReferenceMismatch(
                expected: "Gen.1.1-Gen.1.2",
                actual: "Gen.1.1"
            ),
            coordinator: coordinator,
            target: makeBibleTarget(sourceOSISReference: "Gen.1.1"),
            inventory: makeBibleInventory()
        )
    }

    /**
     Rejects invalid KJVA bounds, exact reference drift, and unavailable strict mapping.

     The target and strict mapper are independently corrupted against a stable source module. Typed
     failures prove persisted KJVA values are evidence to verify, not fallback navigation inputs; a
     failure would permit endpoint invention or public-converter fallback. The fixture is in-memory
     and deterministic.
     */
    func testBiblePlanningRequiresCanonicalPersistedKJVARangeAndFullStrictMapping() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        assertFailure(
            .invalidKJVAOrdinalRange(99...101),
            coordinator: coordinator,
            target: makeBibleTarget(
                kjvaOrdinalRange: 99...101,
                kjvaOSISReference: "Gen.1.1-Gen.1.2"
            ),
            inventory: makeBibleInventory()
        )
        assertFailure(
            .kjvaReferenceMismatch(
                expected: "Gen.1.1-Gen.1.2",
                actual: "Gen.1.1"
            ),
            coordinator: coordinator,
            target: makeBibleTarget(kjvaOSISReference: "Gen.1.1"),
            inventory: makeBibleInventory()
        )
        let noStrictMapping = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon(
            sourceToKJVA: { _, _ in nil }
        ))
        assertFailure(
            .kjvaMappingMismatch,
            coordinator: noStrictMapping,
            target: makeBibleTarget(),
            inventory: makeBibleInventory()
        )
    }

    /**
     Rejects an interior source-to-KJVA mismatch even when both persisted endpoints still agree.

     This prevents endpoint-only validation from accepting a damaged middle verse projection.
     */
    func testBiblePlanningRejectsInteriorKJVADriftWhenRangeEndpointsStillMatch() {
        let third = address(book: "Gen", chapter: 1, verse: 3)
        let sourceVerses = baseSourceVerses + [.init(ordinal: 12, reference: third)]
        let kjvaVerses = baseKJVAVerses + [.init(ordinal: 102, reference: third)]
        let destinationVerses = baseDestinationVerses + [.init(ordinal: 202, reference: third)]
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon(
            sourceVerses: sourceVerses,
            kjvaVerses: kjvaVerses,
            destinationVerses: destinationVerses,
            sourceToKJVA: { reference, _ in
                if reference.verse == 2 {
                    return .init(verse: .init(ordinal: 103, reference: reference))
                }
                let ordinal = reference.verse == 1 ? 100 : 102
                return .init(verse: .init(ordinal: ordinal, reference: reference))
            }
        ))
        let target = makeBibleTarget(
            sourceOrdinalRange: 10...12,
            sourceOSISReference: "Gen.1.1-Gen.1.3",
            kjvaOrdinalRange: 100...102,
            kjvaOSISReference: "Gen.1.1-Gen.1.3"
        )
        let inventory = BibleReaderBookmarkNavigationInventory(
            destinationBible: makeSwordCandidate(
                initials: "DESTINATION",
                category: .bible,
                verses: destinationVerses
            ),
            swordCandidates: [makeSwordCandidate(
                initials: "SOURCE",
                category: .bible,
                verses: sourceVerses
            )]
        )

        assertFailure(
            .kjvaMappingMismatch,
            coordinator: coordinator,
            target: target,
            inventory: inventory
        )
    }

    /**
     Rejects unavailable, unaddressable, irreversible, and nonmonotonic destination mappings.

     Four deterministic destination adapters isolate strict conversion, forward addressability,
     reverse identity, and ordering. Exact failures prove every KJVA verse must survive all checks;
     a failure would allow a partial or reordered reader jump. No commit callbacks or external state
     participate.
     */
    func testBiblePlanningRequiresEveryDestinationVerseToBeStrictAddressableAndMonotonic() {
        let mappingUnavailable = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon(
            kjvaToDestination: { reference, _ in reference.verse == 2 ? nil : reference }
        ))
        assertFailure(
            .destinationMappingUnavailable(kjvaOrdinal: 101),
            coordinator: mappingUnavailable,
            target: makeBibleTarget(),
            inventory: makeBibleInventory()
        )

        let destinationMissingSecond = makeSwordCandidate(
            initials: "DESTINATION",
            category: .bible,
            verses: [baseDestinationVerses[0]]
        )
        assertFailure(
            .destinationOrdinalUnavailable(kjvaOrdinal: 101),
            coordinator: BibleReaderBookmarkNavigationCoordinator(canon: makeCanon()),
            target: makeBibleTarget(),
            inventory: makeBibleInventory(destination: destinationMissingSecond)
        )

        let irreversibleDestination = makeSwordCandidate(
            initials: "DESTINATION",
            category: .bible,
            verses: baseDestinationVerses,
            referenceForOrdinal: { ordinal in
                ordinal == 201 ? nil : self.baseDestinationVerses.first { $0.ordinal == ordinal }
            }
        )
        assertFailure(
            .destinationOrdinalIdentityMismatch(kjvaOrdinal: 101),
            coordinator: BibleReaderBookmarkNavigationCoordinator(canon: makeCanon()),
            target: makeBibleTarget(),
            inventory: makeBibleInventory(destination: irreversibleDestination)
        )

        let descendingDestinationVerses = [
            BibleReaderBookmarkNavigationOrdinalVerse(
                ordinal: 201,
                reference: address(book: "Gen", chapter: 1, verse: 1)
            ),
            BibleReaderBookmarkNavigationOrdinalVerse(
                ordinal: 200,
                reference: address(book: "Gen", chapter: 1, verse: 2)
            ),
        ]
        let descendingDestination = makeSwordCandidate(
            initials: "DESTINATION",
            category: .bible,
            verses: descendingDestinationVerses
        )
        assertFailure(
            .destinationOrdinalsNotMonotonic(previous: 201, current: 200),
            coordinator: BibleReaderBookmarkNavigationCoordinator(canon: makeCanon()),
            target: makeBibleTarget(),
            inventory: makeBibleInventory(destination: descendingDestination)
        )
    }

    /**
     Accepts generic ordinal zero while rejecting malformed target identity and negative ranges.

     A My Documents fragment exposes the exact `0...0` domain after blank identity/key and negative
     range guards are exercised. Success proves Android BVA zero is a real anchor; a failure would
     reintroduce the prior positive-only bug. The fixture performs one in-memory read and no writes.
     */
    func testGenericPlanningAcceptsContainedZeroAndRejectsMalformedPublicFields() throws {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        assertFailure(
            .invalidGenericModuleIdentity,
            coordinator: coordinator,
            target: makeGenericTarget(initials: " "),
            inventory: .init(destinationBible: nil)
        )
        assertFailure(
            .invalidGenericKey,
            coordinator: coordinator,
            target: makeGenericTarget(key: " "),
            inventory: .init(destinationBible: nil)
        )
        assertFailure(
            .invalidGenericOrdinalRange(-1...0),
            coordinator: coordinator,
            target: makeGenericTarget(ordinalRange: -1...0),
            inventory: .init(destinationBible: nil)
        )

        let fragment = makeMyDocumentFragment(initials: "MYDOC", key: "page", range: 0...0)
        let candidate = makeMyDocumentCandidate(fragment: fragment)
        let result = try coordinator.plan(
            target: makeGenericTarget(
                initials: "MYDOC",
                key: "page",
                ordinalRange: 0...0
            ),
            inventory: .init(destinationBible: nil, myDocumentCandidates: [candidate])
        )
        guard case .myDocument(let plan) = result else {
            return XCTFail("Expected a My Documents commit plan")
        }
        XCTAssertEqual(plan.selectedOrdinalRange, 0...0)
        XCTAssertEqual(plan.fragment.ordinalRange, 0...0)
    }

    /**
     Resolves exact initials across all backend inventories before any generic key read.

     Missing, cross-backend duplicate, and unsupported SWORD identities fail with zero lookup calls.
     */
    func testGenericPlanningFailsBeforeKeyLookupForMissingAmbiguousAndUnsupportedIdentity() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        let reads = LookupProbe()
        let sword = makeSwordCandidate(
            initials: "SHARED",
            category: .dictionary,
            fragmentForExactKey: { _ in
                reads.readCount += 1
                return self.makeSwordFragment(initials: "SHARED", key: "entry")
            }
        )
        let document = makeMyDocumentCandidate(
            fragment: makeMyDocumentFragment(initials: "SHARED", key: "entry"),
            onLookup: { reads.readCount += 1 }
        )
        assertFailure(
            .genericModuleNotFound("MISSING"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "MISSING"),
            inventory: .init(destinationBible: nil)
        )
        assertFailure(
            .genericModuleAmbiguous("SHARED"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "SHARED"),
            inventory: .init(
                destinationBible: nil,
                swordCandidates: [sword],
                myDocumentCandidates: [document]
            )
        )
        let unsupported = makeSwordCandidate(
            initials: "BIBLE",
            category: .bible,
            fragmentForExactKey: { _ in
                reads.readCount += 1
                throw StubLookupError.failed
            }
        )
        assertFailure(
            .unsupportedGenericCategory(initials: "BIBLE", actual: .bible),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "BIBLE"),
            inventory: .init(destinationBible: nil, swordCandidates: [unsupported])
        )
        XCTAssertEqual(reads.readCount, 0)
    }

    /**
     Maps exact-key absence separately from ambiguous or failed backend reads.

     SWORD and EPUB fixtures throw canonical-key misses while My Documents reports duplicate page
     identity. Distinct coordinator errors prove retryable/ambiguous reads are not presented as
     ordinary missing content; a failure would hide data corruption. No backend storage is opened.
     */
    func testGenericPlanningReportsTypedExactKeyAbsenceAndLookupFailure() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        let sword = makeSwordCandidate(
            initials: "DICT",
            category: .dictionary,
            fragmentForExactKey: { key in
                throw SwordRawOSISFragmentError.keyNotFound(requested: key, resolved: "other")
            }
        )
        assertFailure(
            .genericKeyUnavailable(moduleInitials: "DICT", key: "entry"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "DICT"),
            inventory: .init(destinationBible: nil, swordCandidates: [sword])
        )

        let document = BibleReaderBookmarkNavigationMyDocumentCandidate(
            documentID: UUID(),
            initials: "MYDOC",
            fragmentForExactKey: { key in
                throw MyDocumentExactLookupError.duplicatePages(
                    bookInitials: "MYDOC",
                    pageKey: key
                )
            }
        )
        assertFailure(
            .genericKeyLookupFailed(moduleInitials: "MYDOC", key: "entry"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "MYDOC"),
            inventory: .init(destinationBible: nil, myDocumentCandidates: [document])
        )

        let epub = makeEpubCandidate(initials: "EPUB") { key in
            throw EpubPersistedKeyLookupError.invalidPersistedKey(key)
        }
        assertFailure(
            .genericKeyUnavailable(moduleInitials: "EPUB", key: "entry"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "EPUB"),
            inventory: .init(destinationBible: nil, epubCandidates: [epub])
        )
    }

    /**
     Rejects returned identity drift, malformed fragment domains, and out-of-fragment selections.

     Detached My Documents and EPUB rows deliberately disagree with the requested key or BVA bounds.
     Exact typed errors prove successful lookup alone is insufficient; a failure would let aliases or
     unrelated anchors pass. The test is deterministic and mutates no reader state.
     */
    func testGenericPlanningRequiresExactFragmentIdentityAndContainedOrdinalRange() {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        let wrongPage = makeMyDocumentCandidate(
            fragment: makeMyDocumentFragment(initials: "MYDOC", key: "other")
        )
        assertFailure(
            .genericFragmentIdentityMismatch(moduleInitials: "MYDOC", key: "entry"),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "MYDOC"),
            inventory: .init(destinationBible: nil, myDocumentCandidates: [wrongPage])
        )

        let malformedContent = makeEpubContent(key: "1", range: -1 ... -1)
        let malformedEpub = makeEpubCandidate(initials: "EPUB") { _ in malformedContent }
        assertFailure(
            .invalidGenericFragmentOrdinalRange(-1 ... -1),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "EPUB", key: "1"),
            inventory: .init(destinationBible: nil, epubCandidates: [malformedEpub])
        )

        let content = makeEpubContent(key: "1", range: 0...1)
        let epub = makeEpubCandidate(initials: "EPUB") { _ in content }
        assertFailure(
            .genericOrdinalOutsideFragment(requested: 0...2, available: 0...1),
            coordinator: coordinator,
            target: makeGenericTarget(initials: "EPUB", key: "1", ordinalRange: 0...2),
            inventory: .init(destinationBible: nil, epubCandidates: [epub])
        )
    }

    /** Returns backend-specific detached plans after one exact key read and no commit effects. */
    func testGenericPlanningReturnsExactSwordMyDocumentAndEpubPlansWithoutCommitEffects() throws {
        let coordinator = BibleReaderBookmarkNavigationCoordinator(canon: makeCanon())
        let sideEffects = PlanningSideEffectProbe()

        let swordFragment = makeSwordFragment(initials: "DICT", key: "entry", range: 0...2)
        let sword = makeSwordCandidate(
            initials: "DICT",
            category: .dictionary,
            fragmentForExactKey: { key in
                sideEffects.keyReads += 1
                XCTAssertEqual(key, "entry")
                return swordFragment
            }
        )
        let swordResult = try coordinator.plan(
            target: makeGenericTarget(
                initials: "DICT",
                key: "entry",
                ordinalRange: 0...1
            ),
            inventory: .init(destinationBible: nil, swordCandidates: [sword])
        )
        guard case .sword(let swordPlan) = swordResult else {
            return XCTFail("Expected a SWORD commit plan")
        }
        XCTAssertEqual(swordPlan.fragment, swordFragment)

        let documentFragment = makeMyDocumentFragment(
            initials: "MYDOC",
            key: "page",
            range: 0...0
        )
        let document = makeMyDocumentCandidate(fragment: documentFragment) {
            sideEffects.keyReads += 1
        }
        let documentResult = try coordinator.plan(
            target: makeGenericTarget(initials: "MYDOC", key: "page", ordinalRange: 0...0),
            inventory: .init(destinationBible: nil, myDocumentCandidates: [document])
        )
        guard case .myDocument(let documentPlan) = documentResult else {
            return XCTFail("Expected a My Documents commit plan")
        }
        XCTAssertEqual(documentPlan.fragment, documentFragment)

        let epubContent = makeEpubContent(key: "1", range: 0...3)
        let epub = makeEpubCandidate(initials: "EPUB") { key in
            sideEffects.keyReads += 1
            XCTAssertEqual(key, "1")
            return epubContent
        }
        let epubResult = try coordinator.plan(
            target: makeGenericTarget(initials: "EPUB", key: "1", ordinalRange: nil),
            inventory: .init(destinationBible: nil, epubCandidates: [epub])
        )
        guard case .epub(let epubPlan) = epubResult else {
            return XCTFail("Expected an EPUB commit plan")
        }
        XCTAssertEqual(epubPlan.content, epubContent)
        XCTAssertEqual(sideEffects.keyReads, 3)
        XCTAssertEqual(sideEffects.readerMutations, 0)
        XCTAssertEqual(sideEffects.persistenceWrites, 0)
        XCTAssertEqual(sideEffects.renderRequests, 0)
    }

    /**
     Verifies every typed navigation failure exposes non-empty localized presentation text.

     The exhaustive value list covers all current associated-value shapes without invoking planner
     I/O. Non-empty output proves callers can present every fail-closed result; a failure means a new
     error path escaped the localized contract. Localization reads are deterministic for fallback
     presence and create no state.
     */
    func testEveryNavigationFailureProvidesLocalizedPresentationText() {
        let failures: [BibleReaderBookmarkNavigationFailure] = [
            .destinationBibleUnavailable,
            .invalidDestinationBibleIdentity,
            .destinationCategoryMismatch(initials: "A", actual: .dictionary),
            .unsupportedDestinationVersification("A"),
            .invalidSourceModuleIdentity,
            .sourceModuleNotFound("A"),
            .sourceModuleAmbiguous("A"),
            .sourceCategoryMismatch(initials: "A", actual: .dictionary),
            .unsupportedSourceVersification("A"),
            .sourceVersificationMismatch(expected: "A", actual: "B"),
            .invalidSourceOrdinalRange(1...1),
            .sourceOrdinalIdentityMismatch(1),
            .sourceReferenceMismatch(expected: "A", actual: "B"),
            .invalidKJVAOrdinalRange(1...1),
            .kjvaReferenceMismatch(expected: "A", actual: "B"),
            .kjvaMappingMismatch,
            .destinationMappingUnavailable(kjvaOrdinal: 1),
            .destinationOrdinalUnavailable(kjvaOrdinal: 1),
            .destinationOrdinalIdentityMismatch(kjvaOrdinal: 1),
            .destinationOrdinalsNotMonotonic(previous: 2, current: 1),
            .invalidGenericModuleIdentity,
            .invalidGenericKey,
            .invalidGenericOrdinalRange(0...0),
            .genericModuleNotFound("A"),
            .genericModuleAmbiguous("A"),
            .unsupportedGenericCategory(initials: "A", actual: .bible),
            .genericKeyUnavailable(moduleInitials: "A", key: "B"),
            .genericKeyLookupFailed(moduleInitials: "A", key: "B"),
            .genericFragmentIdentityMismatch(moduleInitials: "A", key: "B"),
            .invalidGenericFragmentOrdinalRange(0...0),
            .genericOrdinalOutsideFragment(requested: 0...1, available: 0...0),
        ]

        for failure in failures {
            XCTAssertFalse((failure.errorDescription ?? "").isEmpty, "Missing text for \(failure)")
        }
    }

    /** Two normal source verses used by the default deterministic canon. */
    private var baseSourceVerses: [BibleReaderBookmarkNavigationOrdinalVerse] {
        [
            .init(ordinal: 10, reference: address(book: "Gen", chapter: 1, verse: 1)),
            .init(ordinal: 11, reference: address(book: "Gen", chapter: 1, verse: 2)),
        ]
    }

    /** Two matching persisted KJVA verses used by the default deterministic canon. */
    private var baseKJVAVerses: [BibleReaderBookmarkNavigationOrdinalVerse] {
        [
            .init(ordinal: 100, reference: address(book: "Gen", chapter: 1, verse: 1)),
            .init(ordinal: 101, reference: address(book: "Gen", chapter: 1, verse: 2)),
        ]
    }

    /** Two strictly increasing destination verses used by the default deterministic canon. */
    private var baseDestinationVerses: [BibleReaderBookmarkNavigationOrdinalVerse] {
        [
            .init(ordinal: 200, reference: address(book: "Gen", chapter: 1, verse: 1)),
            .init(ordinal: 201, reference: address(book: "Gen", chapter: 1, verse: 2)),
        ]
    }

    /**
     Creates one exact verse address for concise deterministic fixture construction.

     - Parameters:
       - book: OSIS book identifier.
       - chapter: One-based chapter.
       - verse: One-based verse.
     - Returns: Detached address value.
     - Side effects: None.
     - Failure modes: None; tests deliberately control all input validity.
     */
    private func address(
        book: String,
        chapter: Int,
        verse: Int
    ) -> BibleReaderBookmarkNavigationVerseAddress {
        .init(osisBookID: book, chapter: chapter, verse: verse)
    }

    /**
     Creates a deterministic canon with independently replaceable strict mapping operations.

     - Parameters:
       - sourceVerses: Source ordinal/reference table.
       - kjvaVerses: Persisted KJVA ordinal/reference table.
       - destinationVerses: Destination ordinal/reference table used by the default mapper.
       - supportsVersification: Optional support predicate.
       - sourceToKJVA: Optional strict source mapper.
       - kjvaToDestination: Optional strict destination mapper.
     - Returns: Immutable coordinator canon fixture.
     - Side effects: None.
     - Failure modes: Missing table entries return `nil` during planning.
     */
    private func makeCanon(
        sourceVerses: [BibleReaderBookmarkNavigationOrdinalVerse]? = nil,
        kjvaVerses: [BibleReaderBookmarkNavigationOrdinalVerse]? = nil,
        destinationVerses: [BibleReaderBookmarkNavigationOrdinalVerse]? = nil,
        supportsVersification: ((String) -> Bool)? = nil,
        sourceToKJVA: ((
            BibleReaderBookmarkNavigationVerseAddress,
            String
        ) -> BibleReaderBookmarkNavigationKJVAMapping?)? = nil,
        kjvaToDestination: ((
            BibleReaderBookmarkNavigationVerseAddress,
            String
        ) -> BibleReaderBookmarkNavigationVerseAddress?)? = nil
    ) -> BibleReaderBookmarkNavigationCanon {
        let sourceTable = sourceVerses ?? baseSourceVerses
        let kjvaTable = kjvaVerses ?? baseKJVAVerses
        let destinationTable = destinationVerses ?? baseDestinationVerses
        let support = supportsVersification ?? { ["KJV", "KJVA"].contains($0) }
        let sourceMapper = sourceToKJVA ?? { reference, _ in
            kjvaTable.first { $0.reference == reference }.map {
                BibleReaderBookmarkNavigationKJVAMapping(verse: $0)
            }
        }
        let destinationMapper = kjvaToDestination ?? { reference, _ in
            destinationTable.first { $0.reference == reference }?.reference
        }
        return BibleReaderBookmarkNavigationCanon(
            supportsVersification: support,
            sourceReference: { ordinal, _ in
                sourceTable.first { $0.ordinal == ordinal }?.reference
            },
            sourceToKJVA: sourceMapper,
            kjvaVerse: { ordinal in kjvaTable.first { $0.ordinal == ordinal } },
            kjvaToDestination: destinationMapper
        )
    }

    /**
     Creates a read-only SWORD candidate from exact ordinal/reference fixtures.

     - Parameters:
       - initials: Exact module initials.
       - category: Module category.
       - versification: Effective module versification.
       - verses: Exact reverse/forward ordinal table.
       - referenceForOrdinal: Optional reverse-lookup override.
       - ordinalForReference: Optional forward-lookup override.
       - fragmentForExactKey: Optional exact generic fragment reader.
     - Returns: Immutable candidate fixture.
     - Side effects: None during construction.
     - Failure modes: The default fragment reader throws when unexpectedly called.
     */
    private func makeSwordCandidate(
        initials: String,
        category: ModuleCategory,
        versification: String = "KJV",
        verses: [BibleReaderBookmarkNavigationOrdinalVerse] = [],
        referenceForOrdinal: ((Int) -> BibleReaderBookmarkNavigationOrdinalVerse?)? = nil,
        ordinalForReference: ((BibleReaderBookmarkNavigationVerseAddress) -> Int?)? = nil,
        fragmentForExactKey: ((String) throws -> SwordRawOSISFragment)? = nil
    ) -> BibleReaderBookmarkNavigationSwordCandidate {
        let reverse = referenceForOrdinal ?? { ordinal in
            verses.first { $0.ordinal == ordinal }
        }
        let forward = ordinalForReference ?? { reference in
            verses.first { $0.reference == reference }?.ordinal
        }
        let fragment = fragmentForExactKey ?? { _ in throw StubLookupError.failed }
        return .init(
            initials: initials,
            category: category,
            versification: versification,
            referenceForOrdinal: reverse,
            ordinalForReference: forward,
            fragmentForExactKey: fragment
        )
    }

    /**
     Creates the default exact source and already-selected destination inventory.

     - Parameter destination: Optional destination override.
     - Returns: Inventory containing one exact source candidate.
     - Side effects: None.
     - Failure modes: None.
     */
    private func makeBibleInventory(
        destination: BibleReaderBookmarkNavigationSwordCandidate? = nil
    ) -> BibleReaderBookmarkNavigationInventory {
        .init(
            destinationBible: destination ?? makeSwordCandidate(
                initials: "DESTINATION",
                category: .bible,
                verses: baseDestinationVerses
            ),
            swordCandidates: [makeSwordCandidate(
                initials: "SOURCE",
                category: .bible,
                verses: baseSourceVerses
            )]
        )
    }

    /**
     Creates a Bible target whose fields can be independently corrupted by each behavior test.

     - Returns: Typed Bible navigation target wrapped for coordinator dispatch.
     - Side effects: None.
     - Failure modes: None; deliberately invalid combinations are retained for planner tests.
     */
    private func makeBibleTarget(
        sourceModuleInitials: String? = "SOURCE",
        sourceVersification: String = "KJV",
        sourceOrdinalRange: ClosedRange<Int> = 10...11,
        sourceOSISReference: String = "Gen.1.1-Gen.1.2",
        kjvaOrdinalRange: ClosedRange<Int> = 100...101,
        kjvaOSISReference: String = "Gen.1.1-Gen.1.2"
    ) -> BookmarkNavigationTarget {
        .bible(.init(
            sourceModuleInitials: sourceModuleInitials,
            sourceVersification: sourceVersification,
            sourceOrdinalRange: sourceOrdinalRange,
            sourceOSISReference: sourceOSISReference,
            kjvaOrdinalRange: kjvaOrdinalRange,
            kjvaOSISReference: kjvaOSISReference
        ))
    }

    /**
     Creates a generic target retaining exact initials, key, and optional BVA range.

     - Parameters:
       - initials: Unnormalized module identity.
       - key: Unnormalized persisted key.
       - ordinalRange: Optional BVA selection.
     - Returns: Generic target wrapped for coordinator dispatch.
     - Side effects: None.
     - Failure modes: None; malformed values are intentionally retained for negative tests.
     */
    private func makeGenericTarget(
        initials: String = "DICT",
        key: String = "entry",
        ordinalRange: ClosedRange<Int>? = nil
    ) -> BookmarkNavigationTarget {
        .generic(.init(moduleInitials: initials, key: key, ordinalRange: ordinalRange))
    }

    /**
     Creates a detached exact generic SWORD fragment fixture.

     - Parameters:
       - initials: Exact source module identity.
       - key: Exact fragment key.
       - category: Generic SWORD category.
       - range: Available local BVA domain.
     - Returns: Immutable raw-OSIS fragment with matching source metadata.
     - Side effects: None.
     - Failure modes: None; malformed ranges can be deliberately supplied by negative tests.
     */
    private func makeSwordFragment(
        initials: String,
        key: String,
        category: ModuleCategory = .dictionary,
        range: ClosedRange<Int> = 0...0
    ) -> SwordRawOSISFragment {
        let source = SwordRawOSISSource(
            initials: initials,
            name: initials,
            abbreviation: initials,
            category: category,
            language: "en",
            direction: "ltr",
            versification: "KJV",
            hasStrongs: false,
            moduleFeatures: []
        )
        return SwordRawOSISFragment(
            xml: "<div/>",
            originalXML: "<div/>",
            key: key,
            keyName: key,
            fragmentKey: "\(initials)--\(key)",
            osisRef: key,
            source: source,
            isNewTestament: false,
            features: [:],
            contentOrdinalRange: range,
            keyOrdinalRange: nil,
            annotateRef: nil,
            anchorTexts: [:],
            comparablePlainText: nil,
            hasRenderableContent: true
        )
    }

    /**
     Creates a detached My Documents fragment fixture with a caller-selected exact range.

     - Parameters:
       - documentID: Stable parent identity shared with its candidate.
       - initials: Exact module initials.
       - key: Exact page key.
       - range: Available BVA domain.
     - Returns: Immutable page snapshot.
     - Side effects: None.
     - Failure modes: None; identity/range corruption is retained for negative tests.
     */
    private func makeMyDocumentFragment(
        documentID: UUID = UUID(),
        initials: String,
        key: String,
        range: ClosedRange<Int> = 0...0
    ) -> BibleReaderBookmarkNavigationMyDocumentFragment {
        .init(
            documentID: documentID,
            pageID: UUID(),
            moduleInitials: initials,
            documentName: "Document",
            key: key,
            title: "Page",
            contentTypeRawValue: MyDocumentContentType.markdown.rawValue,
            rawContent: "Body",
            languageCode: "en",
            ordinalRange: range
        )
    }

    /**
     Creates a My Documents candidate that returns one exact detached fragment.

     - Parameters:
       - fragment: Snapshot returned for any invoked key so identity guards remain observable.
       - onLookup: Read observer used to prove lookup ordering.
     - Returns: Read-only candidate fixture.
     - Side effects: Invokes `onLookup` once per exact-key read and performs no writes.
     - Failure modes: None; tests model failures with the explicit candidate initializer instead.
     */
    private func makeMyDocumentCandidate(
        fragment: BibleReaderBookmarkNavigationMyDocumentFragment,
        onLookup: @escaping () -> Void = {}
    ) -> BibleReaderBookmarkNavigationMyDocumentCandidate {
        .init(
            documentID: fragment.documentID,
            initials: fragment.moduleInitials,
            fragmentForExactKey: { _ in
                onLookup()
                return fragment
            }
        )
    }

    /**
     Creates one detached EPUB content row with exact persisted-key identity.

     - Parameters:
       - key: Canonical numeric key fixture.
       - range: Available BVA domain.
     - Returns: Immutable indexed-content value.
     - Side effects: None.
     - Failure modes: None; malformed ranges are retained for planner rejection tests.
     */
    private func makeEpubContent(
        key: String,
        range: ClosedRange<Int>
    ) -> EpubReader.Content {
        .init(
            key: key,
            persistedKey: key,
            href: "text/chapter.xhtml",
            fragment: nil,
            title: "Chapter",
            html: "<p>Text</p>",
            ordinalRange: range
        )
    }

    /**
     Creates an EPUB candidate backed by a throwing exact persisted-key resolver.

     - Parameters:
       - initials: Exact Android-style EPUB identity.
       - lookup: Strict resolver behavior under test.
     - Returns: Read-only immutable-generation candidate fixture.
     - Side effects: Stores the closure only; invocation effects belong to the supplied fixture.
     - Failure modes: Propagates resolver errors when planning performs the exact read.
     */
    private func makeEpubCandidate(
        initials: String,
        lookup: @escaping (String) throws -> EpubReader.Content
    ) -> BibleReaderBookmarkNavigationEpubCandidate {
        .init(
            identifier: "epub-id",
            generationIdentifier: "generation",
            initials: initials,
            title: "EPUB",
            language: "en",
            contentForExactPersistedKey: lookup
        )
    }

    /**
     Asserts one planning attempt throws exactly the expected typed failure.

     - Parameters:
       - expected: Exact expected coordinator failure.
       - coordinator: Planner under test.
       - target: Typed bookmark target.
       - inventory: Explicit candidate inventory.
       - file: Calling test source location.
       - line: Calling test source line.
     - Side effects: Records XCTest failures only.
     - Failure modes: Reports missing, untyped, or different thrown errors.
     */
    private func assertFailure(
        _ expected: BibleReaderBookmarkNavigationFailure,
        coordinator: BibleReaderBookmarkNavigationCoordinator,
        target: BookmarkNavigationTarget,
        inventory: BibleReaderBookmarkNavigationInventory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try coordinator.plan(target: target, inventory: inventory),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationFailure,
                expected,
                file: file,
                line: line
            )
        }
    }
}

/**
 Records allowed key reads and forbidden commit effects for pure-planning assertions.

 The fixture intentionally omits all production behavior and only stores synchronous counters.
 Tests mutate `keyReads` from lookup closures; reader, persistence, and render counters must remain
 zero because no such callbacks enter the planner. It performs no I/O and has no failure path.
 */
private final class PlanningSideEffectProbe {
    /// Exact-key reads, which are allowed during planning.
    var keyReads = 0
    /// Reader-state mutations, which planning must never perform.
    var readerMutations = 0
    /// Persistence writes, which planning must never perform.
    var persistenceWrites = 0
    /// Render requests, which planning must never perform.
    var renderRequests = 0
}

/**
 Records candidate read invocation count for preflight-ordering assertions.

 The fixture simulates no backend and stores only a synchronous integer. Candidate closures mutate
 the count; zero proves missing, duplicate, and unsupported identity failures happen before lookup.
 */
private final class LookupProbe {
    /// Number of read attempts observed by the fixture.
    var readCount = 0
}

/**
 Deterministic failure used when a test candidate receives an unexpected lookup.

 It simulates an unreadable backend without I/O or hidden state. Tests that unexpectedly reach the
 closure receive this error, making lookup-order regressions deterministic.
 */
private enum StubLookupError: Error {
    /// Unexpected exact-key read.
    case failed
}
