// BibleReaderSQLiteRuntimeCoordinator.swift -- SQLite discovery and backend ownership policy

import BibleCore
import Foundation
import SwordKit

/**
 Reader inventories produced from genuine SWORD modules and validated Android SQLite modules.

 Each category is case-insensitively de-duplicated, uses the genuine SWORD module's canonical
 metadata when both backends claim one identity, and remains sorted by the catalog contract.
 */
struct BibleReaderSQLiteRuntimeInventories {
    /// Bible metadata visible to module pickers and runtime language projection.
    let bibles: [ModuleInfo]

    /// Commentary metadata visible to module pickers and runtime language projection.
    let commentaries: [ModuleInfo]

    /// Dictionary metadata visible to module pickers and runtime language projection.
    let dictionaries: [ModuleInfo]
}

/**
 SQLite handles that should replace SWORD fallbacks after one manager/catalog refresh.

 A non-nil handle is authoritative for its category. Nil means the controller should retain its
 supported SWORD selection, if any, and clear the stale SQLite handle for that category.
 */
struct BibleReaderSQLiteSelectionResolution {
    /// Requested or first available SQLite Bible when no SWORD Bible owns the selection.
    let bible: BibleReaderSQLiteModuleHandle?

    /// Requested or first available SQLite commentary when no SWORD commentary owns the selection.
    let commentary: BibleReaderSQLiteModuleHandle?

    /// Explicitly requested SQLite dictionary; dictionaries never invent a default selection.
    let dictionary: BibleReaderSQLiteModuleHandle?
}

/**
 Owns Android SQLite discovery and cross-backend identity decisions for the Bible reader.

 The coordinator creates one fresh catalog per SWORD manager refresh, proves which installed rows
 are genuine readable SWORD modules, and applies Android's canonical case-insensitive identity
 policy. It returns immutable decisions for the controller to apply; it never mutates pane state,
 persists selections, or emits reader events.
 */
struct BibleReaderSQLiteRuntimeCoordinator {
    /// Current validated SQLite discovery snapshot and its one immutable handle per module.
    private var catalog = BibleReaderSQLiteModuleCatalog()

    /// Canonical readable SWORD metadata keyed by Android's Java UTF-16 identity.
    private var genuineSwordModulesByIdentity: [SQLiteDocumentIdentity: ModuleInfo] = [:]

    /// Readable SWORD metadata in manager registration order for JSword-compatible lookup.
    private var genuineSwordModulesInRegistrationOrder: [ModuleInfo] = []

    /**
     Rebuilds discovery and merges all reader-visible SQLite categories with SWORD.

     - Parameters:
       - manager: Configured SWORD manager whose module root also contains Android SQLite books.
       - primaryBibles: Bible metadata projected by the SWORD setup coordinator.
       - primaryCommentaries: Commentary metadata projected by the SWORD setup coordinator.
       - primaryDictionaries: Dictionary metadata projected by the SWORD setup coordinator.
     - Returns: Canonical, case-insensitively de-duplicated picker inventories.
     - Side effects: Opens fresh SQLite library connections and asks SWORD to prove native module
       readability. Existing catalog handles remain valid only through external references.
     - Failure modes: Malformed SQLite modules are excluded by discovery; unreadable or synthetic
       SWORD projection rows are excluded from precedence and primary inventories.
     - Important: Each discovered SQLite module receives exactly one immutable runtime handle.
     */
    mutating func reload(
        manager: SwordManager,
        primaryBibles: [ModuleInfo],
        primaryCommentaries: [ModuleInfo],
        primaryDictionaries: [ModuleInfo]
    ) -> BibleReaderSQLiteRuntimeInventories {
        catalog.reload(
            moduleRootURL: URL(fileURLWithPath: manager.modulePath, isDirectory: true)
        )

        var genuine: [SQLiteDocumentIdentity: ModuleInfo] = [:]
        var registeredGenuine: [ModuleInfo] = []
        for info in manager.installedModules()
        where !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) {
            guard manager.module(named: info.name) != nil else { continue }
            let key = Self.identity(info.name)
            if genuine[key] == nil {
                genuine[key] = info
                registeredGenuine.append(info)
            }
        }
        genuineSwordModulesByIdentity = genuine
        genuineSwordModulesInRegistrationOrder = registeredGenuine

        let hasGenuineSwordModule: (String) -> Bool = { name in
            genuine[Self.identity(name)] != nil
        }
        return BibleReaderSQLiteRuntimeInventories(
            bibles: catalog.mergedModules(
                primary: canonicalPrimaryModules(primaryBibles, category: .bible),
                category: .bible,
                hasReadableSwordModule: hasGenuineSwordModule
            ),
            commentaries: catalog.mergedModules(
                primary: canonicalPrimaryModules(primaryCommentaries, category: .commentary),
                category: .commentary,
                hasReadableSwordModule: hasGenuineSwordModule
            ),
            dictionaries: catalog.mergedModules(
                primary: canonicalPrimaryModules(primaryDictionaries, category: .dictionary),
                category: .dictionary,
                hasReadableSwordModule: hasGenuineSwordModule
            )
        )
    }

    /**
     Resolves a SQLite module only when no genuine SWORD module owns the same global identity.

     - Parameters:
       - name: Requested initials; matching uses Java UTF-16 case-insensitive identity.
       - category: Required SQLite runtime category.
     - Returns: The stable immutable handle for this catalog snapshot, or nil when absent,
       category-mismatched, or shadowed by readable SWORD content.
     - Side effects: None.
     - Failure modes: None; unreadable modules never enter the catalog.
     */
    func preferredModule(
        named name: String,
        category: ModuleCategory
    ) -> BibleReaderSQLiteModuleHandle? {
        guard genuineSwordInfo(named: name) == nil,
              let module = catalog.module(named: name),
              genuineSwordInfo(named: module.info.name) == nil,
              module.info.category == category else {
            return nil
        }
        return module
    }

    /**
     Returns SQLite modules that Android's global registry would not shadow with genuine SWORD.

     - Parameter category: Optional category filter applied after registration precedence.
     - Returns: Stable handles in SQLite registration order.
     - Side effects: None.
     - Failure modes: Returns an empty array before reload or when every candidate is shadowed.
     */
    func unshadowedSQLiteModules(
        category: ModuleCategory? = nil
    ) -> [BibleReaderSQLiteModuleHandle] {
        catalog.modulesInRegistrationOrder().filter { module in
            genuineSwordInfo(named: module.info.name) == nil
                && (category == nil || module.info.category == category)
        }
    }

    /**
     Resolves post-refresh SQLite selections without mutating controller state.

     - Parameters:
       - selection: Pane-owned module initials captured before SWORD fallback resolution.
       - hasActiveSwordBible: Whether setup produced a supported SWORD Bible fallback.
       - hasActiveSwordCommentary: Whether setup produced a supported SWORD commentary fallback.
     - Returns: Category-specific SQLite replacements. Bible/commentary may use their first readable
       SQLite fallback only when SWORD supplied no active fallback; dictionary remains explicit.
     - Side effects: None.
     - Failure modes: Missing, wrong-category, and SWORD-shadowed requests resolve to nil.
     - Note: Ordering is deterministic because catalog category lists are initials-sorted.
     */
    func resolveSelections(
        _ selection: BibleReaderSwordSelection,
        hasActiveSwordBible: Bool,
        hasActiveSwordCommentary: Bool
    ) -> BibleReaderSQLiteSelectionResolution {
        let bible = preferredModule(named: selection.activeModuleName, category: .bible)
            ?? (!hasActiveSwordBible ? firstUnshadowedModule(category: .bible) : nil)
        let commentary = selection.activeCommentaryModuleName.flatMap {
            preferredModule(named: $0, category: .commentary)
        } ?? (!hasActiveSwordCommentary ? firstUnshadowedModule(category: .commentary) : nil)
        let dictionary = selection.activeDictionaryModuleName.flatMap {
            preferredModule(named: $0, category: .dictionary)
        }
        return BibleReaderSQLiteSelectionResolution(
            bible: bible,
            commentary: commentary,
            dictionary: dictionary
        )
    }

    /**
     Returns the genuine SWORD spelling for one identity while preserving unresolved requests.

     - Parameter requestedName: Case-insensitive module initials from UI or persisted state.
     - Returns: Canonical native SWORD initials, or the original value when SWORD does not own it.
     - Side effects: None.
     - Failure modes: None.
     */
    func canonicalSwordModuleName(_ requestedName: String) -> String {
        genuineSwordInfo(named: requestedName)?.name ?? requestedName
    }

    /**
     Reports whether readable native SWORD content owns one case-insensitive module identity.

     - Parameter name: Requested module initials.
     - Returns: True only for a non-SQLite-projection SWORD row proven readable during reload.
     - Side effects: None.
     - Failure modes: Returns false before the first successful reload.
     */
    func hasGenuineSwordModule(named name: String) -> Bool {
        genuineSwordInfo(named: name) != nil
    }

    /**
     Returns every distinct non-empty language visible through the merged runtime catalog.

     - Parameter inventories: Current category inventories returned by `reload`.
     - Returns: Deterministically sorted BCP-47 or source language tokens.
     - Side effects: None.
     - Failure modes: Returns an empty array when no module declares a language; callers own their
       UI fallback.
     */
    func activeLanguages(
        inventories: BibleReaderSQLiteRuntimeInventories
    ) -> [String] {
        let all = Array(genuineSwordModulesByIdentity.values)
            + inventories.bibles
            + inventories.commentaries
            + inventories.dictionaries
        return Array(Set(all.map(\.language).filter { !$0.isEmpty })).sorted()
    }

    /**
     Returns the first deterministic SQLite fallback not shadowed by genuine SWORD content.

     - Parameter category: Required Bible or commentary fallback category.
     - Returns: First exact-UTF-16-sorted immutable handle, or nil when none is eligible.
     - Side effects: None.
     - Failure modes: An empty catalog or globally SWORD-owned category returns nil.
     */
    private func firstUnshadowedModule(
        category: ModuleCategory
    ) -> BibleReaderSQLiteModuleHandle? {
        catalog.modules(category: category).first {
            genuineSwordInfo(named: $0.info.name) == nil
        }
    }

    /**
     Replaces synthetic/case-variant SWORD rows with canonical readable metadata.

     - Parameters:
       - primary: Category rows emitted by the existing SWORD setup coordinator.
       - category: Category required by the merged inventory.
     - Returns: Genuine readable SWORD metadata corresponding to primary identities.
     - Side effects: None.
     - Failure modes: Synthetic, unreadable, absent, and wrong-category rows are omitted.
     */
    private func canonicalPrimaryModules(
        _ primary: [ModuleInfo],
        category: ModuleCategory
    ) -> [ModuleInfo] {
        primary.compactMap { info in
            genuineSwordModulesByIdentity[Self.identity(info.name)]
        }.filter { $0.category == category }
    }

    /**
     Returns the stable Java UTF-16 case-insensitive identity shared by runtime decisions.

     - Parameter initials: Exact SWORD or SQLite installed-book initials.
     - Returns: Non-normalizing, non-expanding identity matching `String.equalsIgnoreCase`.
     - Side effects: None.
     - Failure modes: Empty initials produce an empty identity.
     */
    private static func identity(_ initials: String) -> SQLiteDocumentIdentity {
        SQLiteDocumentIdentity(initials)
    }

    /**
     Resolves genuine SWORD metadata with JSword's global exact/full-name/case precedence.

     - Parameter name: Initials or full module name supplied by a bridge, picker, or persisted row.
     - Returns: The SWORD-owned metadata selected before SQLite registration is considered.
     - Side effects: None.
     - Failure modes: Returns nil when no readable genuine SWORD module matches.
     */
    private func genuineSwordInfo(named name: String) -> ModuleInfo? {
        genuineSwordModulesInRegistrationOrder.first {
            Self.javaStringEquals($0.name, name)
        } ?? genuineSwordModulesInRegistrationOrder.last {
            Self.javaStringEquals($0.description, name)
        } ?? {
            let identity = Self.identity(name)
            return genuineSwordModulesInRegistrationOrder.first {
                Self.identity($0.name) == identity || Self.identity($0.description) == identity
            }
        }()
    }

    /** Compares exact Java `String.equals` identities without Unicode normalization. */
    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
