// BibleReaderSQLiteRuntimeCoordinator.swift -- SQLite discovery and backend ownership policy

import BibleCore
import Foundation
import SwordKit

/**
 Reader inventories produced from genuine SWORD modules and validated Android SQLite modules.

 Each category contains the owners admitted to Android's global BookSet and remains in its pinned
 TreeSet order. Exact case variants and canonically distinct UTF-16 identities remain independently
 visible whenever JSword's comparator retains both books.
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

 The coordinator creates one fresh catalog and one shared installed-module resolver per SWORD
 manager refresh. Every inventory, activation, restore, and speech-facing lookup therefore uses the
 same exact maps and pinned TreeSet case tier as Android. It returns immutable decisions for the
 controller to apply; it never mutates pane state, persists selections, unlocks content, or emits
 reader events.
 */
struct BibleReaderSQLiteRuntimeCoordinator {
    /// Current validated SQLite discovery snapshot and its one immutable handle per module.
    private var catalog = BibleReaderSQLiteModuleCatalog()

    /// Shared global BookSet snapshot used by every post-refresh ownership decision.
    private var installedModuleResolver: BibleReaderInstalledModuleResolver?

    /**
     Rebuilds discovery and merges all reader-visible SQLite categories with SWORD.

     - Parameters:
       - manager: Configured SWORD manager whose module root also contains Android SQLite books.
       - primaryBibles: Bible metadata projected by the SWORD setup coordinator.
       - primaryCommentaries: Commentary metadata projected by the SWORD setup coordinator.
       - primaryDictionaries: Dictionary metadata projected by the SWORD setup coordinator.
     - Returns: Globally admitted picker inventories in pinned JSword TreeSet order.
     - Side effects: Opens fresh SQLite library connections and asks SWORD to resolve native module
       ownership. Existing catalog handles remain valid only through external references.
     - Failure modes: Malformed SQLite modules are excluded by discovery; synthetic or unresolvable
       SWORD projection rows are excluded. Locked native rows remain owners so SQLite cannot bypass
       the reader's unlock route.
     - Important: Each discovered SQLite module receives exactly one immutable runtime handle.
     */
    mutating func reload(
        manager: SwordManager,
        primaryBibles: [ModuleInfo],
        primaryCommentaries: [ModuleInfo],
        primaryDictionaries: [ModuleInfo]
    ) -> BibleReaderSQLiteRuntimeInventories {
        let sqliteLibrary = SQLiteDocumentModuleLibrary(
            moduleRootURL: URL(fileURLWithPath: manager.modulePath, isDirectory: true)
        )
        return reload(
            manager: manager,
            sqliteLibrary: sqliteLibrary,
            primaryBibles: primaryBibles,
            primaryCommentaries: primaryCommentaries,
            primaryDictionaries: primaryDictionaries
        )
    }

    /**
     Rebuilds the runtime from one validated raw SQLite discovery sequence.

     Android asks the complete global registry about every custom-driver candidate. The shared
     resolver must therefore see `registrationCandidates`, not the library's custom-only admitted
     list, before the catalog publishes selectable handles.

     - Parameters:
       - manager: Configured SWORD manager supplying native ownership and fresh access state.
       - sqliteLibrary: Validated discovery snapshot retaining raw custom candidates in driver order.
       - primaryBibles: Supported native Bible metadata projected by the SWORD setup coordinator.
       - primaryCommentaries: Supported native commentary metadata from the setup coordinator.
       - primaryDictionaries: Supported native dictionary metadata from the setup coordinator.
     - Returns: Canonical, globally admitted picker inventories for all supported reader categories.
     - Side effects: Resolves native handles, replays custom admission, and replaces the retained
       catalog snapshot; no scripture content is read.
     - Failure modes: Unreadable custom payloads are absent from discovery. Locked native owners
       remain registered and reject collisions without exposing content or permitting fallthrough.
     - Note: This overload is internal so parity tests can supply deterministic in-memory candidates
       while exercising the same runtime selection path used by the controller.
     */
    mutating func reload(
        manager: SwordManager,
        sqliteLibrary: SQLiteDocumentModuleLibrary,
        primaryBibles: [ModuleInfo],
        primaryCommentaries: [ModuleInfo],
        primaryDictionaries: [ModuleInfo]
    ) -> BibleReaderSQLiteRuntimeInventories {
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteLibrary: sqliteLibrary
        )
        installedModuleResolver = resolver
        catalog.reload(
            retaining: sqliteLibrary,
            admittedModulesInRegistrationOrder:
                resolver.registeredSQLiteModulesInRegistrationOrder()
        )
        let registeredMetadata = resolver.registeredBookMetadata()
        return BibleReaderSQLiteRuntimeInventories(
            bibles: Self.inventory(
                registeredMetadata,
                category: .bible,
                primaryNativeMetadata: primaryBibles
            ),
            commentaries: Self.inventory(
                registeredMetadata,
                category: .commentary,
                primaryNativeMetadata: primaryCommentaries
            ),
            dictionaries: Self.inventory(
                registeredMetadata,
                category: .dictionary,
                primaryNativeMetadata: primaryDictionaries
            )
        )
    }

    /**
     Resolves a SQLite module only when Android's global BookSet selects that exact backend.

     - Parameters:
       - name: Requested initials/full-name token resolved by exact maps then TreeSet case scan.
       - category: Required SQLite runtime category.
     - Returns: The stable immutable handle for this catalog snapshot, or nil when absent,
       category-mismatched, or shadowed by resolvable SWORD ownership (including locked content).
     - Side effects: None.
     - Failure modes: None; unreadable modules never enter the catalog.
     */
    func preferredModule(
        named name: String,
        category: ModuleCategory
    ) -> BibleReaderSQLiteModuleHandle? {
        guard let source = installedModuleResolver?.module(named: name),
              case .sqlite(let module) = source,
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
        guard let installedModuleResolver else { return [] }
        return installedModuleResolver.registeredSQLiteModulesInRegistrationOrder().filter {
            category == nil || $0.info.category == category
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
     - Note: Ordering is deterministic because catalog category lists use JSword TreeSet order.
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
     Returns the globally selected native SWORD spelling while preserving unresolved requests.

     - Parameter requestedName: Initials/full-name token from UI or persisted state.
     - Returns: Canonical native SWORD initials, or the original value when SWORD does not own it.
     - Side effects: None.
     - Failure modes: None.
     */
    func canonicalSwordModuleName(_ requestedName: String) -> String {
        guard let installedModuleResolver,
              installedModuleResolver.hasNativeRegistration(named: requestedName),
              let info = installedModuleResolver.registeredModuleInfo(named: requestedName) else {
            return requestedName
        }
        return info.name
    }

    /**
     Reports whether the global BookSet selects a resolvable native SWORD owner.

     - Parameter name: Requested initials/full-name token.
     - Returns: True for a resolvable non-SQLite-projection SWORD row, including a locked owner.
     - Side effects: None.
     - Failure modes: Returns false before the first successful reload.
     */
    func hasGenuineSwordModule(named name: String) -> Bool {
        installedModuleResolver?.hasNativeRegistration(named: name) ?? false
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
        let all = (installedModuleResolver?.registeredBookMetadata() ?? [])
            + inventories.bibles
            + inventories.commentaries
            + inventories.dictionaries
        return Array(Set(all.map(\.language).filter { !$0.isEmpty })).sorted()
    }

    /**
     Returns the first deterministic SQLite fallback admitted by the global BookSet.

     - Parameter category: Required Bible or commentary fallback category.
     - Returns: First JSword-TreeSet-ordered immutable handle, or nil when none is eligible.
     - Side effects: None.
     - Failure modes: An empty catalog or globally SWORD-owned category returns nil.
     */
    private func firstUnshadowedModule(
        category: ModuleCategory
    ) -> BibleReaderSQLiteModuleHandle? {
        catalog.modules(category: category).first
    }

    /**
     Restricts one global BookSet category to the coordinator-supported native rows plus SQLite.

     - Parameters:
       - registeredMetadata: Globally admitted books in pinned TreeSet order.
       - category: Reader picker category being projected.
       - primaryNativeMetadata: Supported native rows from the SWORD setup coordinator.
     - Returns: TreeSet-ordered metadata retaining every admitted SQLite row and only exact UTF-16
       native identities already accepted by the setup coordinator.
     - Side effects: None.
     - Failure modes: Stale or unsupported native rows are omitted. Composed/decomposed and exact
       case variants are never collapsed by Swift canonical equality or a case-folded dictionary.
     */
    private static func inventory(
        _ registeredMetadata: [ModuleInfo],
        category: ModuleCategory,
        primaryNativeMetadata: [ModuleInfo]
    ) -> [ModuleInfo] {
        registeredMetadata.filter { info in
            guard info.category == category else { return false }
            if BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) { return true }
            return primaryNativeMetadata.contains {
                SwordJavaStringIdentity.equals($0.name, info.name)
            }
        }
    }
}
