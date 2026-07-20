// BibleReaderModuleSwitchCoordinator.swift -- Module/category switch planning for reader panes

import BibleCore
import SwordKit
import os.log

private let moduleSwitchLogger = Logger(subsystem: "org.andbible", category: "BibleReaderController")

/**
 Describes why a requested module/category switch cannot be planned.

 These failures are intentionally pure value types so controller-facing code can keep logging,
 installed-module lookup, active SWORD module mutation, persistence callbacks, and WebView reloads
 outside the rule collaborator.
 */
enum BibleReaderModuleSwitchFailure: Error, Equatable {
    /// The resolved SWORD module category does not match the document category being selected.
    case categoryMismatch(moduleName: String, expected: DocumentCategory, actual: ModuleCategory)
}

/**
 Supplies controller-owned state mutations to the module switch coordinator.

 The coordinator owns the switching rules, but the controller still owns observed reader state,
 SWORD module references, and WebView rendering. Keeping those mutations as explicit closures
 avoids making the coordinator retain a reader controller while still moving the switching workflow
 out of the large controller file.

 Inputs:
 - current SWORD manager, active window, client-ready state, and visible category snapshot
 - category-specific setters for active modules and selected keys
 - callbacks for book-list refresh, persistence, and content reload

 Outputs:
 - no return value; switch operations invoke closures to mutate controller/page state

 Side effects:
 - switch operations may mutate controller state, active `PageManager` fields, persist SwiftData, and
   reload rendered content through the supplied callbacks

 Failure modes:
 - if a closure target has gone away, weak controller closures can become no-ops; switch methods will
   still avoid creating fallback state not backed by the controller
 */
struct BibleReaderModuleSwitchContext {
    let swordManager: SwordManager?
    let activeWindow: Window?
    let clientReady: Bool
    let currentCategory: DocumentCategory
    let setBibleModule: (SwordModule, String) -> Void
    let setCommentaryModule: (SwordModule, String) -> Void
    let setDictionaryModule: (SwordModule, String) -> Void
    let setGeneralBookModule: (SwordModule, String) -> Void
    let setMapModule: (SwordModule, String) -> Void
    let setCurrentCategory: (DocumentCategory) -> Void
    let refreshBookList: () -> Void
    let moduleBookListCount: () -> Int
    let persistState: () -> Void
    let loadCurrentContent: () -> Void
}

/**
 Applies a category-specific module selection to a pane's `PageManager`.

 The plan mirrors Android's durable `PageManager` fields: every document category owns its selected
 module independently, and document-switch paths may also update `currentCategoryName` atomically.

 Inputs:
 - `moduleName`: installed SWORD module initials to persist for the target category
 - `category`: durable document category that owns the module field
 - `updatesVisibleCategory`: whether applying the plan also changes the active PageManager category

 Outputs:
 - `apply(to:)` mutates the supplied PageManager in place and returns no value.

 Side effects:
 - writes the category-owned module field
 - clears stale entry keys for dictionary, general-book, and map selections
 - optionally writes `currentCategoryName`

 Failure modes:
 - unsupported categories currently have no module-owned PageManager field, so applying them only
   updates `currentCategoryName` when requested
 */
struct BibleReaderModuleSwitchPlan: Equatable {
    let moduleName: String
    let category: DocumentCategory
    let updatesVisibleCategory: Bool

    /**
     Writes this switch plan to the pane page manager.

     - Parameter pageManager: Page state to update for the selected category.
     - Side effects: Mutates category-specific module/key fields and, for document switches,
       `currentCategoryName`.
     - Failure modes: Categories without module fields are intentionally ignored except for the
       visible category write, preserving the caller's explicit category ownership.
     */
    func apply(to pageManager: PageManager) {
        switch category {
        case .bible:
            pageManager.bibleDocument = moduleName
        case .commentary:
            pageManager.commentaryDocument = moduleName
        case .dictionary:
            pageManager.dictionaryDocument = moduleName
            pageManager.dictionaryKey = nil
        case .generalBook:
            pageManager.generalBookDocument = moduleName
            pageManager.generalBookKey = nil
        case .map:
            pageManager.mapDocument = moduleName
            pageManager.mapKey = nil
        case .epub, .dailyDevotion:
            break
        }

        guard updatesVisibleCategory else { return }
        pageManager.currentCategoryName = category.pageManagerKey
    }
}

/**
 Applies a category-only switch to a pane's `PageManager`.

 The controller remains responsible for updating its observed `currentCategory`, deciding whether
 the JavaScript client is ready, and performing the actual reload. This value only records the
 durable category write and whether content should be reloaded after the category change.
 */
struct BibleReaderCategorySwitchPlan: Equatable {
    let category: DocumentCategory
    let shouldReloadContent: Bool

    /**
     Writes this category switch to the pane page manager.

     - Parameter pageManager: Page state to update with the selected category.
     - Side effects: Mutates `currentCategoryName`.
     - Failure modes: None; every `DocumentCategory` has a durable PageManager key.
     */
    func apply(to pageManager: PageManager) {
        pageManager.currentCategoryName = category.pageManagerKey
    }
}

/**
 Plans reader module/category switches without owning active SWORD modules or WebView reloads.

 Android routes current-document selection through one durable page-manager transition: the selected
 document and visible category are updated together before the reader reloads. This coordinator
 isolates those rules from `BibleReaderController` so the controller can remain the orchestration
 boundary for module lookup, active-module assignment, persistence callbacks, and rendering.
 */
struct BibleReaderModuleSwitchCoordinator {
    /**
     Switches the selected Bible module without changing the visible document category.

     - Parameters:
       - moduleName: Installed Bible module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active Bible module state, refreshes the book list, persists
       `PageManager.bibleDocument`, and reloads current content when the client is ready.
     - Failure modes: Logs and leaves state unchanged when the module cannot be resolved.
     */
    func switchModule(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "module") else {
            return
        }

        context.setBibleModule(mod, moduleName)
        context.refreshBookList()
        moduleSwitchLogger.info("Switched to module: \(moduleName) (\(context.moduleBookListCount()) books)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .bible),
            context: context
        )

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the visible document to a Bible module in one Android-parity transition.

     Android's `CurrentPageManager.setCurrentDocument(book)` updates the selected Bible and active
     page together before notifying the reader. This keeps iOS on the same contract for toolbar
     quick selectors and full module-picker selections.

     - Parameters:
       - moduleName: Installed SWORD Bible module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active Bible module/category state, persists `bibleDocument` and
       `currentCategoryName` together, and reloads once when the client is ready.
     - Failure modes: Logs and leaves state unchanged when the module is missing or is not a Bible.
     */
    func switchBibleDocument(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "Bible document") else {
            return
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .bible,
            logSubject: "Bible document"
        ) else {
            return
        }

        context.setBibleModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        context.refreshBookList()
        moduleSwitchLogger.info("Switched to Bible document: \(moduleName) (\(context.moduleBookListCount()) books)")

        persist(plan, context: context)

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the selected commentary module without changing the visible document category.

     - Parameters:
       - moduleName: Installed commentary module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active commentary module state, persists
       `PageManager.commentaryDocument`, and reloads only when commentary is already visible.
     - Failure modes: Logs and leaves state unchanged when the module cannot be resolved.
     */
    func switchCommentaryModule(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "commentary module") else {
            return
        }

        context.setCommentaryModule(mod, moduleName)
        moduleSwitchLogger.info("Switched to commentary module: \(moduleName)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .commentary),
            context: context
        )

        guard context.clientReady, context.currentCategory == .commentary else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the visible document to a commentary module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed commentary module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active commentary module/category state, persists
       `commentaryDocument` and `currentCategoryName` together, and reloads once when ready.
     - Failure modes: Logs and leaves state unchanged when the module is missing or not commentary.
     */
    func switchCommentaryDocument(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "commentary document") else {
            return
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .commentary,
            logSubject: "commentary document"
        ) else {
            return
        }

        context.setCommentaryModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to commentary document: \(moduleName)")

        persist(plan, context: context)

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the selected dictionary module without changing the visible document category.

     - Parameters:
       - moduleName: Installed dictionary module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active dictionary state, clears stale dictionary keys, and persists the
       dictionary module/key fields.
     - Failure modes: Logs and leaves state unchanged when the module cannot be resolved.
     */
    func switchDictionaryModule(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "dictionary module") else {
            return
        }

        context.setDictionaryModule(mod, moduleName)
        moduleSwitchLogger.info("Switched to dictionary module: \(moduleName)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .dictionary),
            context: context
        )
    }

    /**
     Switches the visible document to a dictionary module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed dictionary module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active dictionary/category state, clears stale dictionary keys, persists
       dictionary document/category fields together, and reloads once when ready.
     - Failure modes: Logs and leaves state unchanged when the module is missing or not a dictionary.
     */
    func switchDictionaryDocument(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "dictionary document") else {
            return
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .dictionary,
            logSubject: "dictionary document"
        ) else {
            return
        }

        context.setDictionaryModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to dictionary document: \(moduleName)")

        persist(plan, context: context)

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the selected general-book module without changing the visible document category.

     - Parameters:
       - moduleName: Installed general-book module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active general-book state, clears stale keys, and persists the selected
       general-book module/key fields.
     - Failure modes: Logs and leaves state unchanged when the module cannot be resolved.
     */
    func switchGeneralBookModule(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "general book module") else {
            return
        }

        context.setGeneralBookModule(mod, moduleName)
        moduleSwitchLogger.info("Switched to general book module: \(moduleName)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .generalBook),
            context: context
        )
    }

    /**
     Switches the visible document to a general-book module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed general-book module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active general-book/category state, clears stale keys, persists
       general-book document/category fields together, and reloads once when ready.
     - Failure modes: Logs and leaves state unchanged when the module is missing or not a general
       book.
     */
    func switchGeneralBookDocument(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "general book document") else {
            return
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .generalBook,
            logSubject: "general book document"
        ) else {
            return
        }

        context.setGeneralBookModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to general book document: \(moduleName)")

        persist(plan, context: context)

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the selected map module without changing the visible document category.

     - Parameters:
       - moduleName: Installed map module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active map state, clears stale map keys, and persists map module/key
       fields.
     - Failure modes: Logs and leaves state unchanged when the module cannot be resolved.
     */
    func switchMapModule(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "map module") else {
            return
        }

        context.setMapModule(mod, moduleName)
        moduleSwitchLogger.info("Switched to map module: \(moduleName)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .map),
            context: context
        )
    }

    /**
     Switches the visible document to a map module in one Android-parity transition.

     Android's document chooser routes maps through `setCurrentDocument(book)`, so map selections
     update the selected map, clear stale map entry state, and switch the visible category as one
     durable page-manager write before content reload.

     - Parameters:
       - moduleName: Installed map module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active map/category state, clears stale map keys, persists map
       document/category fields together, and reloads once when ready.
     - Failure modes: Logs and leaves state unchanged when the module is missing or not a map.
     */
    func switchMapDocument(to moduleName: String, context: BibleReaderModuleSwitchContext) {
        guard let mod = module(named: moduleName, context: context, logSubject: "map document") else {
            return
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .map,
            logSubject: "map document"
        ) else {
            return
        }

        context.setMapModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to map document: \(moduleName)")

        persist(plan, context: context)

        guard context.clientReady else { return }
        context.loadCurrentContent()
    }

    /**
     Switches the visible document category without changing selected modules.

     - Parameters:
       - category: Category that should become visible.
       - context: Controller-owned state and callbacks for the active pane.
     - Side effects: Mutates active category state, persists `currentCategoryName`, and reloads only
       when the category actually changed and the client is ready.
     - Failure modes: None.
     */
    func switchCategory(to category: DocumentCategory, context: BibleReaderModuleSwitchContext) {
        let plan = categorySwitchPlan(from: context.currentCategory, to: category)
        context.setCurrentCategory(plan.category)
        persist(plan, context: context)

        guard context.clientReady, plan.shouldReloadContent else { return }
        context.loadCurrentContent()
    }

    /**
     Builds an Android-style current-document switch plan.

     - Parameters:
       - moduleName: Installed module initials to persist.
       - moduleCategory: Resolved SWORD category for the installed module.
       - targetCategory: Visible document category the caller is trying to select.
     - Returns: A switch plan that updates the selected module and current category together, or a
       category mismatch failure when the installed module cannot satisfy the requested category.
     - Side effects: None.
     - Failure modes: Returns `.categoryMismatch` without mutating page state when the module
       category does not map to `targetCategory`.
     */
    func documentSwitchPlan(
        moduleName: String,
        moduleCategory: ModuleCategory,
        targetCategory: DocumentCategory
    ) -> Result<BibleReaderModuleSwitchPlan, BibleReaderModuleSwitchFailure> {
        guard Self.documentCategory(for: moduleCategory) == targetCategory else {
            return .failure(.categoryMismatch(
                moduleName: moduleName,
                expected: targetCategory,
                actual: moduleCategory
            ))
        }

        return .success(BibleReaderModuleSwitchPlan(
            moduleName: moduleName,
            category: targetCategory,
            updatesVisibleCategory: true
        ))
    }

    /**
     Builds a module-only switch plan.

     Direct module-switch actions update the selected module for a category without changing which
     category is visible. Full current-document chooser paths should use `documentSwitchPlan` so the
     selected module and visible category are persisted together like Android.

     - Parameters:
       - moduleName: Installed module initials to persist.
       - targetCategory: Category-owned module field to update.
     - Returns: A switch plan that updates only the category-owned module/key fields.
     - Side effects: None.
     - Failure modes: None; callers that need installed-module validation do it before planning.
     */
    func moduleOnlySwitchPlan(
        moduleName: String,
        targetCategory: DocumentCategory
    ) -> BibleReaderModuleSwitchPlan {
        BibleReaderModuleSwitchPlan(
            moduleName: moduleName,
            category: targetCategory,
            updatesVisibleCategory: false
        )
    }

    /**
     Builds a category-only switch plan.

     - Parameters:
       - oldCategory: Currently visible category before the switch.
       - newCategory: Category that should become visible.
     - Returns: A plan that always writes the selected category and requests a reload only when the
       visible category actually changes.
     - Side effects: None.
     - Failure modes: None.
     */
    func categorySwitchPlan(
        from oldCategory: DocumentCategory,
        to newCategory: DocumentCategory
    ) -> BibleReaderCategorySwitchPlan {
        BibleReaderCategorySwitchPlan(
            category: newCategory,
            shouldReloadContent: oldCategory != newCategory
        )
    }

    /**
     Maps installed SWORD module categories onto the durable document categories iOS can display.

     - Parameter moduleCategory: SWORD module category reported by the installed module.
     - Returns: Matching document category, or `nil` when the module category is unsupported by the
       reader switch surface.
     - Side effects: None.
     - Failure modes: Unsupported categories return nil so document switch planning rejects them
       without creating iOS-only fallback behavior.
     */
    private static func documentCategory(for moduleCategory: ModuleCategory) -> DocumentCategory? {
        switch moduleCategory {
        case .bible:
            return .bible
        case .commentary:
            return .commentary
        case .dictionary:
            return .dictionary
        case .generalBook:
            return .generalBook
        case .map:
            return .map
        case .dailyDevotion, .glossary, .addon, .unknown:
            return nil
        }
    }

    /**
     Resolves an installed module for a switch workflow.

     - Parameters:
       - moduleName: Installed module initials to resolve.
       - context: Controller state containing the current SWORD manager.
       - logSubject: Human-readable switch target used in warning logs.
     - Returns: The resolved module, or nil when the manager/module is unavailable.
     - Side effects: Emits a warning when resolution fails.
     - Failure modes: Missing manager or module returns nil without mutating state.
     */
    private func module(
        named moduleName: String,
        context: BibleReaderModuleSwitchContext,
        logSubject: String
    ) -> SwordModule? {
        guard let mgr = context.swordManager,
              let mod = mgr.module(named: moduleName) else {
            moduleSwitchLogger.warning("Cannot switch to \(logSubject) \(moduleName) — not found")
            return nil
        }
        return mod
    }


    /**
     Validates an installed module category and logs the controller-compatible warning on mismatch.

     - Parameters:
       - moduleName: Installed module initials being selected.
       - moduleCategory: Category reported by SWORD for the resolved module.
       - targetCategory: Visible category the caller is trying to select.
       - logSubject: Human-readable switch target used in warning logs.
     - Returns: A valid document switch plan, or nil when the module category does not match.
     - Side effects: Emits a warning on mismatch.
     - Failure modes: Category mismatch returns nil and leaves caller state unchanged.
     */
    private func validatedDocumentSwitchPlan(
        moduleName: String,
        moduleCategory: ModuleCategory,
        targetCategory: DocumentCategory,
        logSubject: String
    ) -> BibleReaderModuleSwitchPlan? {
        switch documentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: moduleCategory,
            targetCategory: targetCategory
        ) {
        case .success(let plan):
            return plan
        case .failure:
            moduleSwitchLogger.warning("Cannot switch to \(logSubject) \(moduleName) — category \(moduleCategory.rawValue)")
            return nil
        }
    }

    /**
     Persists a module switch plan through the active pane page manager.

     - Parameters:
       - plan: Category-specific module switch to persist.
       - context: Controller state containing the active window and persistence callback.
     - Side effects: Mutates `PageManager` fields and invokes `persistState` once when a page manager
       is available.
     - Failure modes: Missing active page manager is a no-op, matching prior controller behavior.
     */
    private func persist(
        _ plan: BibleReaderModuleSwitchPlan,
        context: BibleReaderModuleSwitchContext
    ) {
        guard let pageManager = context.activeWindow?.pageManager else { return }
        plan.apply(to: pageManager)
        context.persistState()
    }

    /**
     Persists a category switch plan through the active pane page manager.

     - Parameters:
       - plan: Category switch to persist.
       - context: Controller state containing the active window and persistence callback.
     - Side effects: Mutates `PageManager.currentCategoryName` and invokes `persistState` once when
       a page manager is available.
     - Failure modes: Missing active page manager is a no-op, matching prior controller behavior.
     */
    private func persist(
        _ plan: BibleReaderCategorySwitchPlan,
        context: BibleReaderModuleSwitchContext
    ) {
        guard let pageManager = context.activeWindow?.pageManager else { return }
        plan.apply(to: pageManager)
        context.persistState()
    }
}
