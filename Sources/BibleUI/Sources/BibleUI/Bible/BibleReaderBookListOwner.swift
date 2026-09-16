// BibleReaderBookListOwner.swift -- Exact active-backend ownership for Bible book inventories

import SwordKit

/**
 Identifies the exact installed source generation that owns one active Bible book list.

 Names alone are insufficient because a module can be replaced at the same path with the same
 initials. The manager and backend references retain exact runtime identity, while both manager and
 canonical module-root generations invalidate reuse after unlock, refresh, install, uninstall, or
 restore publication. The controller's installed-source generation also invalidates reuse whenever
 its combined SWORD/SQLite registry is rebuilt, even if a test or injected runtime retains the same
 manager and module objects.

 Values are confined to the reader controller's existing synchronous state boundary. Constructing
 or comparing an identity performs no native reads and cannot fail.
 */
struct BibleReaderBookListSourceIdentity: Equatable {
    /** Reader backend family that determines how the inventory is loaded. */
    enum Backend: Equatable {
        /// Native SWORD `SwordModule` inventory.
        case sword

        /// Validated Android SQLite module inventory.
        case sqlite
    }

    /// Exact manager whose installed registry authorized the backend.
    private let managerOwner: AnyObject

    /// Exact SWORD or SQLite runtime handle that owns the books.
    private let moduleOwner: AnyObject

    /// Backend family used to prevent native/SQLite reuse across an ownership transition.
    private let backend: Backend

    /// Manager-local generation advanced by unlock and explicit refresh.
    private let managerGeneration: UInt64

    /// Canonical module-root generation advanced by every coordinated live-tree mutation.
    private let moduleStoreGeneration: UInt64

    /// Controller-local generation advanced by every combined installed-source rebuild.
    private let installedSourceGeneration: UInt64

    /**
     Captures one exact active backend and the generation that authorized it.

     - Parameters:
       - managerOwner: Current `SwordManager` or a deterministic test owner.
       - moduleOwner: Current `SwordModule`/SQLite handle or a deterministic test owner.
       - backend: Backend family used to load the list.
       - managerGeneration: Manager-local authorization generation.
       - moduleStoreGeneration: Canonical installed-root mutation generation.
       - installedSourceGeneration: Controller-local combined-registry generation.
     - Side effects: Retains both owner objects for as long as the identity is cached.
     - Failure modes: None. Callers must construct identities only after current-inventory
       authorization succeeds.
     */
    init(
        managerOwner: AnyObject,
        moduleOwner: AnyObject,
        backend: Backend,
        managerGeneration: UInt64,
        moduleStoreGeneration: UInt64,
        installedSourceGeneration: UInt64
    ) {
        self.managerOwner = managerOwner
        self.moduleOwner = moduleOwner
        self.backend = backend
        self.managerGeneration = managerGeneration
        self.moduleStoreGeneration = moduleStoreGeneration
        self.installedSourceGeneration = installedSourceGeneration
    }

    /**
     Compares exact runtime owners, backend family, and all authorization generations.

     - Returns: `true` only when both values describe the same manager object, module object,
       backend, manager generation, canonical root generation, and controller registry generation.
     - Side effects: None.
     - Failure modes: None; application strings and Swift canonical equality are never consulted.
     */
    static func == (
        lhs: BibleReaderBookListSourceIdentity,
        rhs: BibleReaderBookListSourceIdentity
    ) -> Bool {
        lhs.managerOwner === rhs.managerOwner
            && lhs.moduleOwner === rhs.moduleOwner
            && lhs.backend == rhs.backend
            && lhs.managerGeneration == rhs.managerGeneration
            && lhs.moduleStoreGeneration == rhs.moduleStoreGeneration
            && lhs.installedSourceGeneration == rhs.installedSourceGeneration
    }
}

/**
 Captures the installed-registry generation that authorized one controller's runtime handles.

 A current root generation cannot authorize handles cached by an older manager. This witness keeps
 the generation observed while the manager and SQLite catalog were rebuilt, then creates a reusable
 source identity only while the exact manager and all generations still match. Stable-generation
 admission remains the `SwordManager` root-lease owner's responsibility.
 */
struct BibleReaderBookListRegistryWitness {
    /// Exact manager whose registry was rebuilt under the captured root read lease.
    private let managerOwner: AnyObject

    /// Manager-local generation that authorized the captured native handles.
    private let managerGeneration: UInt64

    /// Stable even module-root generation that authorized both backend catalogs.
    private let moduleStoreGeneration: UInt64

    /// Controller-local generation for the combined SWORD/SQLite catalog.
    private let installedSourceGeneration: UInt64

    /**
     Records the authorization generation observed during one combined registry rebuild.

     - Parameters:
       - managerOwner: Exact manager rebuilt by the controller.
       - managerGeneration: Manager-local generation observed under the root read lease.
       - moduleStoreGeneration: Root generation observed under the same lease.
       - installedSourceGeneration: Controller registry generation for this rebuild.
     - Side effects: Retains the manager while the controller keeps the witness.
     - Failure modes: None. `sourceIdentityIfCurrent` rejects an obsolete generation.
     */
    init(
        managerOwner: AnyObject,
        managerGeneration: UInt64,
        moduleStoreGeneration: UInt64,
        installedSourceGeneration: UInt64
    ) {
        self.managerOwner = managerOwner
        self.managerGeneration = managerGeneration
        self.moduleStoreGeneration = moduleStoreGeneration
        self.installedSourceGeneration = installedSourceGeneration
    }

    /**
     Creates an exact source identity only while the captured registry remains authoritative.

     - Parameters:
       - managerOwner: Controller's current manager after resolving the module owner.
       - moduleOwner: Exact native or SQLite handle returned by the captured registry.
       - backend: Backend family that owns the handle.
       - managerGeneration: Current manager-local generation read under a root read lease.
       - moduleStoreGeneration: Current root generation read under the same lease.
       - installedSourceGeneration: Current controller registry generation.
     - Returns: A reusable identity for the captured generation, or nil after manager replacement,
       unlock/refresh, root mutation, or registry rebuild.
     - Side effects: A successful identity retains the exact module owner.
     - Failure modes: Fails closed without reading module content.
     */
    func sourceIdentityIfCurrent(
        managerOwner: AnyObject,
        moduleOwner: AnyObject,
        backend: BibleReaderBookListSourceIdentity.Backend,
        managerGeneration: UInt64,
        moduleStoreGeneration: UInt64,
        installedSourceGeneration: UInt64
    ) -> BibleReaderBookListSourceIdentity? {
        guard self.managerOwner === managerOwner,
              self.managerGeneration == managerGeneration,
              self.moduleStoreGeneration == moduleStoreGeneration,
              self.installedSourceGeneration == installedSourceGeneration else {
            return nil
        }
        return BibleReaderBookListSourceIdentity(
            managerOwner: self.managerOwner,
            moduleOwner: moduleOwner,
            backend: backend,
            managerGeneration: self.managerGeneration,
            moduleStoreGeneration: self.moduleStoreGeneration,
            installedSourceGeneration: self.installedSourceGeneration
        )
    }
}

/**
 Owns the last non-empty book inventory accepted for one exact active reader source.

 Android retains `DocumentBibleBooks` by concrete `AbstractPassageBook` and evicts the cache when
 Books reports an add/remove. This owner applies the equivalent iOS boundary without relying on
 initials: exact manager/module objects and authorization generations must all still match. Empty
 and failed loads are never retained, so transient backend failure remains retryable.

 The owner is intentionally controller-scoped and unsynchronized. Callers use it only from the
 same synchronous controller boundary that owns active module handles and `moduleBookList`.
 */
struct BibleReaderBookListOwner {
    /// Source identity attached to `books`, or nil when no reusable value exists.
    private var source: BibleReaderBookListSourceIdentity?

    /// Last authoritative non-empty inventory for `source`.
    private var books: [BookInfo]?

    /**
     Reuses an owned inventory or invokes a fresh backend load.

     - Parameters:
       - source: Exact current installed-source identity captured after authorization.
       - load: Synchronous source read used when ownership or generation differs.
     - Returns: Cached books for an exact hit, otherwise the loader's result.
     - Side effects: Retains a newly loaded non-empty result. Empty results and thrown errors evict
       every prior owner so later calls perform a fresh read.
     - Throws: Rethrows the loader's error after invalidating prior state.
     - Important: Invocation is deterministic for a stable identity; a retained non-empty hit never
       invokes `load`.
     */
    mutating func resolve(
        for source: BibleReaderBookListSourceIdentity,
        load: () throws -> [BookInfo]
    ) rethrows -> [BookInfo] {
        if self.source == source, let books, !books.isEmpty {
            return books
        }

        do {
            let loaded = try load()
            record(loaded, for: source)
            return loaded
        } catch {
            invalidate()
            throw error
        }
    }

    /**
     Adopts a book list already discovered while the same source generation was configured.

     - Parameters:
       - books: Ordered module-specific books; an empty list represents no authoritative value.
       - source: Exact installed source that produced the list, or nil when ownership is uncertain.
     - Side effects: Replaces the retained owner/value only for a non-empty list with known source;
       otherwise evicts prior state.
     - Failure modes: None.
     */
    mutating func record(
        _ books: [BookInfo],
        for source: BibleReaderBookListSourceIdentity?
    ) {
        guard let source, !books.isEmpty else {
            invalidate()
            return
        }
        self.source = source
        self.books = books
    }

    /**
     Evicts the retained inventory when no backend or generation can prove ownership.

     - Side effects: Releases the retained manager, module, and books.
     - Failure modes: None; repeated invalidation is idempotent.
     */
    mutating func invalidate() {
        source = nil
        books = nil
    }
}
