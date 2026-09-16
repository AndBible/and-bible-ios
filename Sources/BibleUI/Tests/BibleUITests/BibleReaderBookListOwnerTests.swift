// BibleReaderBookListOwnerTests.swift -- Active-source book inventory ownership coverage

import SwordKit
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Verifies that reader book-list reuse follows Android's concrete-book cache boundary.

 The suite uses reference-only manager/module owners and immutable `BookInfo` values. No SWORD,
 SQLite, filesystem, or app runtime is initialized. Failures mean a repeated switch can either
 repeat an expensive traversal for an unchanged source or reuse books across an ownership change.
 */
final class BibleReaderBookListOwnerTests: XCTestCase {
    /// Deterministic reference identity used in place of manager and backend objects.
    private final class Owner {}

    /// Retryable loader failure used to verify eviction before error propagation.
    private enum LoaderError: Error {
        /// The simulated backend could not enumerate books.
        case unavailable
    }

    /**
     Proves an exact manager/module/generation hit reuses its non-empty inventory.

     - Side effects: Increments one local loader counter; no native or persisted state is touched.
     - Failure meaning: Returning to an already-selected Bible still repeats the full key traversal.
     */
    func testExactSourceGenerationReusesNonEmptyBooks() {
        var owner = BibleReaderBookListOwner()
        let manager = Owner()
        let module = Owner()
        let source = makeSource(manager: manager, module: module)
        var loadCount = 0

        let first = owner.resolve(for: source) {
            loadCount += 1
            return [Self.genesis]
        }
        let second = owner.resolve(for: source) {
            loadCount += 1
            return [Self.exodus]
        }

        XCTAssertEqual(first, [Self.genesis])
        XCTAssertEqual(second, [Self.genesis])
        XCTAssertEqual(loadCount, 1)
    }

    /**
     Proves configuration can publish its already-discovered inventory into the shared owner.

     - Side effects: Records an in-memory list and tracks whether a fallback loader runs.
     - Failure meaning: Manager configuration followed by controller refresh repeats the native
       SWORD traversal even though both operations use the same authorized source generation.
     */
    func testConfiguredInventoryAvoidsImmediateSecondLoad() {
        var owner = BibleReaderBookListOwner()
        let source = makeSource(manager: Owner(), module: Owner())
        var loadCount = 0

        owner.record([Self.genesis], for: source)
        let resolved = owner.resolve(for: source) {
            loadCount += 1
            return [Self.exodus]
        }

        XCTAssertEqual(resolved, [Self.genesis])
        XCTAssertEqual(loadCount, 0)
    }

    /**
     Proves a final SQLite selection cannot reuse the provisional native configuration inventory.

     - Side effects: Records and resolves in-memory inventories only.
     - Failure meaning: `configureSwordManager` can retain native books after SQLite resolution
       selects the same-named or another serialized Bible as the final backend.
     */
    func testSQLiteFinalSelectionRejectsProvisionalNativeInventory() {
        var owner = BibleReaderBookListOwner()
        let manager = Owner()
        let nativeSource = makeSource(manager: manager, module: Owner())
        let sqliteSource = makeSource(manager: manager, module: Owner(), backend: .sqlite)
        var sqliteLoadCount = 0

        owner.record([Self.genesis], for: nativeSource)
        let resolved = owner.resolve(for: sqliteSource) {
            sqliteLoadCount += 1
            return [Self.exodus]
        }

        XCTAssertEqual(resolved, [Self.exodus])
        XCTAssertEqual(sqliteLoadCount, 1)
    }

    /**
     Proves registry witnesses cannot authorize old handles with a different owner or generation.

     - Side effects: Retains isolated reference owners only.
     - Failure meaning: A publication, unlock, manager replacement, or registry rebuild can stamp an
       old module handle as current and permit stale inventory reuse before controller reconciliation.
     */
    func testRegistryWitnessRejectsChangedOwnersAndGenerations() {
        let manager = Owner()
        let module = Owner()
        let witness = BibleReaderBookListRegistryWitness(
            managerOwner: manager,
            managerGeneration: 7,
            moduleStoreGeneration: 10,
            installedSourceGeneration: 13
        )

        XCTAssertNotNil(witness.sourceIdentityIfCurrent(
            managerOwner: manager,
            moduleOwner: module,
            backend: .sword,
            managerGeneration: 7,
            moduleStoreGeneration: 10,
            installedSourceGeneration: 13
        ))
        XCTAssertNil(witness.sourceIdentityIfCurrent(
            managerOwner: Owner(),
            moduleOwner: module,
            backend: .sword,
            managerGeneration: 7,
            moduleStoreGeneration: 10,
            installedSourceGeneration: 13
        ))
        XCTAssertNil(witness.sourceIdentityIfCurrent(
            managerOwner: manager,
            moduleOwner: module,
            backend: .sword,
            managerGeneration: 8,
            moduleStoreGeneration: 10,
            installedSourceGeneration: 13
        ))
        XCTAssertNil(witness.sourceIdentityIfCurrent(
            managerOwner: manager,
            moduleOwner: module,
            backend: .sword,
            managerGeneration: 7,
            moduleStoreGeneration: 12,
            installedSourceGeneration: 13
        ))
        XCTAssertNil(witness.sourceIdentityIfCurrent(
            managerOwner: manager,
            moduleOwner: module,
            backend: .sword,
            managerGeneration: 7,
            moduleStoreGeneration: 10,
            installedSourceGeneration: 14
        ))

    }

    /**
     Proves every installed-source ownership dimension independently forces a fresh load.

     - Side effects: Builds isolated reference identities and invokes in-memory loaders only.
     - Failure meaning: Same-name replacement, manager or combined-registry rebuild, unlock/refresh,
       module-store change, or native/SQLite transition can retain a stale canon.
     */
    func testEveryOwnerOrGenerationChangeForcesFreshLoad() {
        let originalManager = Owner()
        let originalModule = Owner()
        let original = makeSource(manager: originalManager, module: originalModule)
        let replacements = [
            makeSource(manager: Owner(), module: originalModule),
            makeSource(manager: originalManager, module: Owner()),
            makeSource(manager: originalManager, module: originalModule, backend: .sqlite),
            makeSource(manager: originalManager, module: originalModule, managerGeneration: 8),
            makeSource(manager: originalManager, module: originalModule, moduleStoreGeneration: 12),
            makeSource(
                manager: originalManager,
                module: originalModule,
                installedSourceGeneration: 14
            ),
        ]

        for replacement in replacements {
            var owner = BibleReaderBookListOwner()
            var loadCount = 0
            _ = owner.resolve(for: original) {
                loadCount += 1
                return [Self.genesis]
            }
            let refreshed = owner.resolve(for: replacement) {
                loadCount += 1
                return [Self.exodus]
            }

            XCTAssertEqual(refreshed, [Self.exodus])
            XCTAssertEqual(loadCount, 2)
        }
    }

    /**
     Proves empty discovery never becomes an authoritative cached inventory.

     - Side effects: Invokes one local loader twice; no native or persisted state is touched.
     - Failure meaning: A transient locked, unavailable, or unreadable result can permanently hide
       books after the backend becomes readable.
     */
    func testEmptyResultRemainsRetryableForSameSource() {
        var owner = BibleReaderBookListOwner()
        let source = makeSource(manager: Owner(), module: Owner())
        var loadCount = 0

        let empty = owner.resolve(for: source) {
            loadCount += 1
            return []
        }
        let recovered = owner.resolve(for: source) {
            loadCount += 1
            return [Self.genesis]
        }

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(recovered, [Self.genesis])
        XCTAssertEqual(loadCount, 2)
    }

    /**
     Proves a failed replacement evicts the previous source before propagating its error.

     - Side effects: Mutates one in-memory cache and loader counter only.
     - Failure meaning: Switching back after a failed source read can revive an inventory retained
       across an unvalidated replacement attempt.
     */
    func testFailedLoadEvictsPreviouslyOwnedInventory() throws {
        var owner = BibleReaderBookListOwner()
        let manager = Owner()
        let original = makeSource(manager: manager, module: Owner())
        let replacement = makeSource(manager: manager, module: Owner())
        var originalLoadCount = 0

        _ = owner.resolve(for: original) {
            originalLoadCount += 1
            return [Self.genesis]
        }
        XCTAssertThrowsError(try owner.resolve(for: replacement) {
            throw LoaderError.unavailable
        }) { error in
            XCTAssertTrue(error is LoaderError)
        }
        let restored = owner.resolve(for: original) {
            originalLoadCount += 1
            return [Self.exodus]
        }

        XCTAssertEqual(restored, [Self.exodus])
        XCTAssertEqual(originalLoadCount, 2)
    }

    /**
     Builds an exact source identity for one in-memory test owner pair.

     - Parameters:
       - manager: Reference representing the installed-registry owner.
       - module: Reference representing the active backend owner.
       - backend: Native or SQLite family; defaults to native SWORD.
       - managerGeneration: Unlock/refresh generation; defaults to seven.
       - moduleStoreGeneration: Stable even canonical root generation; defaults to ten.
       - installedSourceGeneration: Controller registry generation; defaults to thirteen.
     - Returns: Immutable identity used by the production owner policy.
     - Side effects: Retains `manager` and `module` through the returned value.
     - Failure modes: None.
     */
    private func makeSource(
        manager: Owner,
        module: Owner,
        backend: BibleReaderBookListSourceIdentity.Backend = .sword,
        managerGeneration: UInt64 = 7,
        moduleStoreGeneration: UInt64 = 10,
        installedSourceGeneration: UInt64 = 13
    ) -> BibleReaderBookListSourceIdentity {
        BibleReaderBookListSourceIdentity(
            managerOwner: manager,
            moduleOwner: module,
            backend: backend,
            managerGeneration: managerGeneration,
            moduleStoreGeneration: moduleStoreGeneration,
            installedSourceGeneration: installedSourceGeneration
        )
    }

    /// Stable non-empty first inventory used to distinguish retained from refreshed values.
    private static let genesis = BookInfo(
        name: "Genesis",
        osisId: "Gen",
        abbreviation: "Gen",
        chapterCount: 50,
        testament: 1
    )

    /// Stable replacement inventory used to prove a loader actually ran.
    private static let exodus = BookInfo(
        name: "Exodus",
        osisId: "Exod",
        abbreviation: "Exod",
        chapterCount: 40,
        testament: 1
    )
}
