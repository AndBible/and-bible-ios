// BibleReaderSQLiteModuleCatalog.swift -- Android SQLite module inventory projection

import Foundation
import BibleCore
import SwordKit

/**
 Maintains the reader-facing catalog for Android MyBible, MySword, and e-Sword modules.

 Android registers these database-backed books beside SWORD books. The iOS reader keeps their raw
 SQLite payloads authoritative and merges only their validated metadata into the existing picker
 inventory. A real SWORD module wins an initials collision because it was registered first by the
 primary backend; an unopenable MyBible sidecar projection may be replaced by the readable SQLite
 module carrying the same identity.
 */
struct BibleReaderSQLiteModuleCatalog {
    /** Exact facade identity of one handle admitted into the current catalog snapshot. */
    private struct CurrentHandleIdentity: Hashable {
        /// Process-local identity of the immutable runtime facade.
        let moduleIdentity: ObjectIdentifier

        /// Java-exact initials paired with that facade identity at publication.
        let initials: SwordJavaExactStringIdentity
    }

    /** One completed discovery/admission publication retained as an indivisible value. */
    private struct Snapshot {
        /// Validated discovery owner retaining the raw readers behind every admitted handle.
        let library: SQLiteDocumentModuleLibrary

        /// Stable handles in Android registration order for JSword-compatible name resolution.
        let handlesInRegistrationOrder: [BibleReaderSQLiteModuleHandle]

        /// Exact facade memberships derived once from the admitted handles above.
        let currentHandleIdentities: Set<CurrentHandleIdentity>

        /** Builds exact membership for one already-admitted handle sequence. */
        init(
            library: SQLiteDocumentModuleLibrary,
            handlesInRegistrationOrder: [BibleReaderSQLiteModuleHandle]
        ) {
            self.library = library
            self.handlesInRegistrationOrder = handlesInRegistrationOrder
            currentHandleIdentities = Set(handlesInRegistrationOrder.map { module in
                CurrentHandleIdentity(
                    moduleIdentity: ObjectIdentifier(module),
                    initials: SwordJavaExactStringIdentity(module.info.name)
                )
            })
        }
    }

    /// Latest validated discovery, admitted handles, and exact current-handle membership.
    private var snapshot: Snapshot?

    /**
     Shared BookSet registrations retaining exact SQLite handles and parsed config metadata.

     - Returns: Current handles in Android custom-driver add order.
     - Side effects: None.
     - Failure modes: Returns an empty array before reload.
     */
    private var bookSetRegistrations: [
        BibleReaderInstalledBookSetRegistration<BibleReaderSQLiteModuleHandle>
    ] {
        (snapshot?.handlesInRegistrationOrder ?? []).map { module in
            BibleReaderInstalledBookSetRegistration(
                value: module,
                initials: module.info.name,
                fullName: module.info.description,
                abbreviation: BibleReaderJSwordConfigValue.abbreviation(
                    module.metadata.abbreviation,
                    initials: module.info.name
                ),
                category: module.info.category
            )
        }
    }

    /**
     Reloads all Android-compatible SQLite families beneath the installed module root.

     A reload creates fresh readers and exactly one immutable runtime handle per discovered module.
     Existing speech sessions may retain handles from the prior snapshot; built-in readers give
     every operation its own connection, so snapshots share no mutable SQLite statement state.

     - Parameter moduleRootURL: Installed root containing Android SQLite family directories.
     - Side effects: Enumerates files, opens validated read-only readers, and replaces the retained
       discovery snapshot and handles. Java-equal identities keep discovery's first module without
       canonically normalizing distinct UTF-16 spellings.
     - Failure modes: Individual unreadable payloads remain catalog diagnostics and are omitted;
       missing roots produce an empty catalog.
     - Note: Discovery order is authoritative for SQLite-to-SQLite duplicates.
     */
    mutating func reload(moduleRootURL: URL) {
        let library = SQLiteDocumentModuleLibrary(moduleRootURL: moduleRootURL)
        var discoveredHandles: [SQLiteDocumentIdentity: BibleReaderSQLiteModuleHandle] = [:]
        var registeredHandles: [BibleReaderSQLiteModuleHandle] = []
        for module in library.modules {
            let key = SQLiteDocumentIdentity(module.info.name)
            guard discoveredHandles[key] == nil else { continue }
            let handle = BibleReaderSQLiteModuleHandle(module: module)
            discoveredHandles[key] = handle
            registeredHandles.append(handle)
        }
        reload(
            retaining: library,
            admittedModulesInRegistrationOrder: registeredHandles
        )
    }

    /**
     Publishes handles already admitted through Android's complete native-plus-custom registry.

     - Parameters:
       - library: Validated discovery snapshot retained for the lifetime of its runtime handles.
       - admittedModulesInRegistrationOrder: Exact handles returned by the shared installed-module
         resolver after replaying raw custom candidates against native and earlier custom owners.
     - Side effects: Replaces the retained discovery snapshot and current runtime handles without
       opening files, recreating handles, or applying a second ownership filter.
     - Failure modes: None. The caller must supply only validated handles from `library`; an empty
       admitted list intentionally clears the catalog while retaining the current snapshot.
     - Important: Do not derive this input from `library.modules` in a combined runtime. That list
       represents custom-only admission and cannot reproduce native-rejection cascades.
     */
    mutating func reload(
        retaining library: SQLiteDocumentModuleLibrary,
        admittedModulesInRegistrationOrder: [BibleReaderSQLiteModuleHandle]
    ) {
        snapshot = Snapshot(
            library: library,
            handlesInRegistrationOrder: admittedModulesInRegistrationOrder
        )
    }

    /**
     Resolves one readable SQLite module through JSword's exact maps and TreeSet case tier.

     - Parameters:
       - name: Requested installed-book initials.
       - category: Optional category constraint preventing cross-category resolution.
     - Returns: Stable immutable handle from the current snapshot, or nil when absent/mismatched.
     - Side effects: Loads the pinned Android case table for case-insensitive fallback.
     - Failure modes: Invalid and Java-equal SWORD-shadowed identities fail closed.
     */
    func module(named name: String, category: ModuleCategory? = nil) -> BibleReaderSQLiteModuleHandle? {
        let resolved = BibleReaderInstalledBookSet.registration(
            named: name,
            in: bookSetRegistrations
        )?.value
        guard let resolved,
              category == nil || resolved.info.category == category else {
            return nil
        }
        return resolved
    }

    /**
     Returns readable SQLite modules in one installed-book category.

     - Parameter category: Required reader inventory category.
     - Returns: Stable handles in JSword's category/abbreviation/initials/name TreeSet order.
     - Side effects: Loads the pinned Android case table for abbreviation ordering.
     - Failure modes: Returns an empty array before reload or when no module matches.
     - Note: Canonically equivalent composed/decomposed identities remain distinct.
     */
    func modules(category: ModuleCategory) -> [BibleReaderSQLiteModuleHandle] {
        BibleReaderInstalledBookSet.treeSetOrderProjection(bookSetRegistrations)
            .map(\.value)
            .filter { $0.info.category == category }
    }

    /**
     Returns every readable SQLite module in Android registration order.

     - Returns: Stable handles ordered MyBible, MySword, then e-Sword as discovered by BibleCore.
     - Side effects: None.
     - Failure modes: Returns an empty array before reload or when no module is readable.
     */
    func modulesInRegistrationOrder() -> [BibleReaderSQLiteModuleHandle] {
        snapshot?.handlesInRegistrationOrder ?? []
    }

    /**
     Tests whether an exact SQLite facade still belongs to the latest admitted catalog snapshot.

     Both object identity and Java-exact UTF-16 initials must match the same published handle.
     A fresh handle carrying reused initials therefore cannot authorize work prepared against an
     older reload, while canonically equivalent Java-distinct initials remain independent.

     - Parameters:
       - moduleIdentity: `ObjectIdentifier` captured from the immutable facade being validated.
       - initials: Raw module initials captured with that facade.
     - Returns: True only when the exact facade/initials pair was admitted by the latest reload.
     - Side effects: None; membership reads the already-built catalog snapshot without discovery,
       registry replay, filesystem access, or handle creation.
     - Failure modes: Returns false before reload, after an empty reload, for a retired facade, or
       when either object identity or exact UTF-16 initials differs.
     - Concurrency: The coordinator must serialize this value-type catalog's reloads with reads;
       each reload assigns one complete immutable snapshot so readers never observe a mixed index.
     */
    func containsCurrentHandle(
        moduleIdentity: ObjectIdentifier,
        initials: String
    ) -> Bool {
        snapshot?.currentHandleIdentities.contains(
            CurrentHandleIdentity(
                moduleIdentity: moduleIdentity,
                initials: SwordJavaExactStringIdentity(initials)
            )
        ) ?? false
    }

    /**
     Returns whether inventory metadata is an Android SQLite projection rather than native SWORD.

     These drivers are registered in Android's global book registry but cannot be opened by
     libsword. Filtering them before precedence checks prevents a case-variant sidecar row from
     being mistaken for the genuine SWORD module that owns the same initials.

     - Parameter info: Installed inventory metadata to classify.
     - Returns: True for supported MyBible, MySword, or e-Sword projection drivers.
     - Side effects: None.
     - Failure modes: Unknown/empty drivers return false so only proven projections are removed.
     */
    static func isSQLiteProjection(_ info: ModuleInfo) -> Bool {
        switch info.moduleDriver.lowercased() {
        case "mybiblebible",
             "mybiblecommentary",
             "mybibledictionary",
             "myswordbible",
             "myswordcommentary",
             "mysworddictionary",
             "eswordbible":
            return true
        default:
            return false
        }
    }

}
