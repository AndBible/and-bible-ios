// BibleReaderSQLiteModuleSwitchCoordinator.swift -- Atomic SQLite category switches

import BibleCore
import SwordKit

/**
 Controller-owned seams used to apply one SQLite module switch atomically.

 The closures keep observable state and PageManager ownership in `BibleReaderController` while the
 coordinator owns backend resolution, dictionary preflight, reload conditions, and operation order.
 */
struct BibleReaderSQLiteModuleSwitchContext {
    /// Resolves a stable, SWORD-unshadowed immutable SQLite module.
    let resolveModule: (_ name: String, _ category: ModuleCategory) -> BibleReaderSQLiteModuleHandle?

    /// Returns the exact currently selected dictionary key.
    let currentDictionaryKey: () -> String?

    /// Returns the category visible before a non-visible switch.
    let currentCategory: () -> DocumentCategory

    /// Reports whether reader bridge emissions can be dispatched immediately.
    let isClientReady: () -> Bool

    /// Makes a SQLite Bible authoritative and clears its SWORD counterpart.
    let activateBible: (BibleReaderSQLiteModuleHandle) -> Void

    /// Makes a SQLite commentary authoritative and clears its SWORD counterpart.
    let activateCommentary: (BibleReaderSQLiteModuleHandle) -> Void

    /// Makes a SQLite dictionary/key pair authoritative and clears its SWORD counterpart.
    let activateDictionary: (BibleReaderSQLiteModuleHandle, String?) -> Void

    /// Updates the visible document category when the caller requested a visible switch.
    let setCurrentCategory: (DocumentCategory) -> Void

    /// Refreshes active Bible books after a Bible backend change.
    let refreshBookList: () -> Void

    /// Persists one category-owned module/key and optional visible-category transition.
    let persistSelection: (
        _ category: DocumentCategory,
        _ moduleName: String,
        _ key: String?,
        _ updatesVisibleCategory: Bool
    ) -> Void

    /// Dispatches the controller's current content after all state and persistence are complete.
    let reloadContent: () -> Void
}

/**
 Coordinates Android-parity SQLite module switches without owning reader or pane state.

 Every operation resolves a readable SWORD-unshadowed handle, applies mutually exclusive backend
 state, persists category fields, then reloads only under the same conditions as the corresponding
 SWORD path. Dictionary enumeration completes before any state mutation.
 */
struct BibleReaderSQLiteModuleSwitchCoordinator {
    /// Exact-key chooser used for fail-before-mutation dictionary preflight.
    private let dictionaryChooser = BibleReaderSQLiteDictionaryChooser()

    /**
     Applies one SQLite Bible switch.

     - Parameters:
       - moduleName: Requested case-insensitive initials.
       - updatesVisibleCategory: Whether Bible becomes the visible category.
       - context: Controller state, persistence, and dispatch seams.
       - prepareForSwitch: Optional caller-owned preparation invoked after module resolution and
         immediately before the successful activation sequence.
     - Returns: True only when SQLite owns and applies the request.
     - Side effects: May run `prepareForSwitch`, then clears SWORD Bible state, refreshes real books,
       persists selection, and reloads content whenever the client is ready.
     - Failure modes: Unknown, wrong-category, and SWORD-shadowed requests return false without
       invoking `prepareForSwitch` or mutating state.
     */
    @discardableResult
    func switchBible(
        to moduleName: String,
        updatesVisibleCategory: Bool,
        context: BibleReaderSQLiteModuleSwitchContext,
        prepareForSwitch: (() -> Void)? = nil
    ) -> Bool {
        guard let module = context.resolveModule(moduleName, .bible) else { return false }
        prepareForSwitch?()
        context.activateBible(module)
        if updatesVisibleCategory { context.setCurrentCategory(.bible) }
        context.refreshBookList()
        context.persistSelection(.bible, module.info.name, nil, updatesVisibleCategory)
        if context.isClientReady() { context.reloadContent() }
        return true
    }

    /**
     Applies one SQLite commentary switch.

     - Parameters:
       - moduleName: Requested case-insensitive initials.
       - updatesVisibleCategory: Whether commentary becomes the visible category.
       - context: Controller state, persistence, and dispatch seams.
     - Returns: True only when SQLite owns and applies the request.
     - Side effects: Clears SWORD commentary state, persists selection, and reloads when commentary
       is or becomes visible and the client is ready.
     - Failure modes: Unknown, wrong-category, and SWORD-shadowed requests return false unchanged.
     */
    @discardableResult
    func switchCommentary(
        to moduleName: String,
        updatesVisibleCategory: Bool,
        context: BibleReaderSQLiteModuleSwitchContext
    ) -> Bool {
        guard let module = context.resolveModule(moduleName, .commentary) else { return false }
        context.activateCommentary(module)
        if updatesVisibleCategory { context.setCurrentCategory(.commentary) }
        context.persistSelection(.commentary, module.info.name, nil, updatesVisibleCategory)
        if context.isClientReady(),
           updatesVisibleCategory || context.currentCategory() == .commentary {
            context.reloadContent()
        }
        return true
    }

    /**
     Preflights and applies one exact-key SQLite dictionary switch.

     - Parameters:
       - moduleName: Requested case-insensitive initials.
       - updatesVisibleCategory: Whether dictionary becomes the visible category.
       - context: Controller state, persistence, and dispatch seams.
     - Returns: Nil when SQLite does not own the request; otherwise exact-key preservation,
       chooser-required, or retryable failure.
     - Side effects: Enumerates keys before mutation, then clears SWORD dictionary state, persists
       the exact retained key, and reloads retained visible content when ready.
     - Failure modes: Enumeration errors return `.failed` before any state/persistence callback.
     */
    func switchDictionary(
        to moduleName: String,
        updatesVisibleCategory: Bool,
        context: BibleReaderSQLiteModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome? {
        guard let module = context.resolveModule(moduleName, .dictionary) else { return nil }
        let plan: BibleReaderSQLiteDictionarySwitchPlan
        do {
            plan = try dictionaryChooser.switchPlan(
                module: module,
                currentKey: context.currentDictionaryKey()
            )
        } catch {
            return .failed(message: error.localizedDescription)
        }
        context.activateDictionary(plan.module, plan.retainedKey)
        if updatesVisibleCategory { context.setCurrentCategory(.dictionary) }
        context.persistSelection(
            .dictionary,
            plan.module.info.name,
            plan.retainedKey,
            updatesVisibleCategory
        )
        if context.isClientReady(), updatesVisibleCategory, plan.retainedKey != nil {
            context.reloadContent()
        }
        return plan.outcome
    }
}
