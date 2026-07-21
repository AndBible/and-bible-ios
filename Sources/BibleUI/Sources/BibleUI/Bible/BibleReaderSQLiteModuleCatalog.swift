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
    /// Latest validated discovery snapshot retained privately so raw unchecked modules cannot leak.
    private var library: SQLiteDocumentModuleLibrary?

    /// Stable handles in Android registration order for JSword-compatible name resolution.
    private var handlesInRegistrationOrder: [BibleReaderSQLiteModuleHandle] = []

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
        self.library = library
        var discoveredHandles: [SQLiteDocumentIdentity: BibleReaderSQLiteModuleHandle] = [:]
        var registeredHandles: [BibleReaderSQLiteModuleHandle] = []
        for module in library.modules {
            let key = SQLiteDocumentIdentity(module.info.name)
            guard discoveredHandles[key] == nil else { continue }
            let handle = BibleReaderSQLiteModuleHandle(module: module)
            discoveredHandles[key] = handle
            registeredHandles.append(handle)
        }
        handlesInRegistrationOrder = registeredHandles
    }

    /**
     Resolves one readable SQLite module by Java UTF-16 case-insensitive initials identity.

     - Parameters:
       - name: Requested installed-book initials.
       - category: Optional category constraint preventing cross-category resolution.
     - Returns: Stable immutable handle from the current snapshot, or nil when absent/mismatched.
     - Side effects: None.
     - Failure modes: Invalid and Java-equal SWORD-shadowed identities fail closed.
     */
    func module(named name: String, category: ModuleCategory? = nil) -> BibleReaderSQLiteModuleHandle? {
        let resolved = handlesInRegistrationOrder.first {
            Self.javaStringEquals($0.info.name, name)
        } ?? handlesInRegistrationOrder.last {
            Self.javaStringEquals($0.info.description, name)
        } ?? {
            let identity = SQLiteDocumentIdentity(name)
            return handlesInRegistrationOrder.first {
                SQLiteDocumentIdentity($0.info.name) == identity
                    || SQLiteDocumentIdentity($0.info.description) == identity
            }
        }()
        guard let resolved,
              category == nil || resolved.info.category == category else {
            return nil
        }
        return resolved
    }

    /**
     Returns readable SQLite modules in one installed-book category.

     - Parameter category: Required reader inventory category.
     - Returns: UTF-16-sorted stable handles from the current snapshot.
     - Side effects: None.
     - Failure modes: Returns an empty array before reload or when no module matches.
     - Note: Sorting compares exact UTF-16 code units and performs no canonical normalization.
     */
    func modules(category: ModuleCategory) -> [BibleReaderSQLiteModuleHandle] {
        handlesInRegistrationOrder
            .filter { $0.info.category == category }
            .sorted { Self.sortsBefore($0.info.name, $1.info.name) }
    }

    /**
     Returns every readable SQLite module in Android registration order.

     - Returns: Stable handles ordered MyBible, MySword, then e-Sword as discovered by BibleCore.
     - Side effects: None.
     - Failure modes: Returns an empty array before reload or when no module is readable.
     */
    func modulesInRegistrationOrder() -> [BibleReaderSQLiteModuleHandle] {
        handlesInRegistrationOrder
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

    /**
     Merges one SWORD coordinator category with readable SQLite books.

     - Parameters:
       - primary: Metadata already returned by the SWORD coordinator.
       - category: Category being projected into a picker.
       - hasReadableSwordModule: Reports whether an initials token resolves to a real SWORD module.
     - Returns: Stable initials-sorted metadata with one case-insensitive row per identity.
     - Side effects: None.
     - Failure modes: None; malformed SQLite modules were excluded during discovery.
     */
    func mergedModules(
        primary: [ModuleInfo],
        category: ModuleCategory,
        hasReadableSwordModule: (String) -> Bool
    ) -> [ModuleInfo] {
        var mergedByIdentity: [SQLiteDocumentIdentity: ModuleInfo] = [:]
        for info in primary where info.category == category {
            mergedByIdentity[SQLiteDocumentIdentity(info.name)] = info
        }
        for module in modules(category: category) {
            let key = SQLiteDocumentIdentity(module.info.name)
            if hasReadableSwordModule(module.info.name) {
                continue
            }
            mergedByIdentity[key] = module.info
        }
        return mergedByIdentity.values.sorted { Self.sortsBefore($0.name, $1.name) }
    }

    /**
     Compares exact initials in Java-compatible UTF-16 lexical order for stable picker output.

     - Parameters:
       - lhs: First exact initials string.
       - rhs: Second exact initials string.
     - Returns: `true` when `lhs` precedes `rhs` by unsigned UTF-16 code unit.
     - Side effects: None.
     - Failure modes: None; equal strings do not precede one another.
     */
    private static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    /** Compares exact Java `String.equals` identities without Unicode normalization. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
