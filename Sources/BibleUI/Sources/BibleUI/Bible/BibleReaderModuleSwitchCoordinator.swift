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
 Reports whether a requested native SWORD Bible activation completed or needs user authorization.

 The outcome is produced before any controller, `PageManager`, persistence, or WebView mutation when
 a target is locked or unavailable. Full document pickers can use `.requiresUnlock` to present the
 existing passphrase workflow, while non-interactive callers fail closed and keep their readable
 current document.

 The value is deterministic for the manager snapshot used by one synchronous switch attempt and has
 no side effects by itself.
 */
public enum BibleReaderBibleModuleSwitchOutcome: Equatable, Sendable {
    /// The module was activated and the existing persistence/render sequence completed.
    case switched

    /// The installed encrypted module needs a verified key before activation can continue.
    case requiresUnlock(moduleName: String)

    /// The requested native module was missing, unsupported, unreadable, or category-incompatible.
    case unavailable
}

/**
 Reports whether a commentary module or document switch completed.

 Commentary does not own a separate generic-key chooser, but callers still need a typed success
 boundary so authorization failures cannot be mistaken for a completed switch. Locked, missing,
 and unsupported targets fail before controller, persistence, or WebView mutation; document
 switches also reject category-incompatible targets at that boundary.
 */
public enum BibleReaderCommentaryModuleSwitchOutcome: Equatable, Sendable {
    /// The readable commentary target was activated and the requested persistence/render work ran.
    case switched

    /// Fresh access or category validation failed without changing reader state.
    case failed
}

/**
 Reports the user-visible result of switching a dictionary, general-book, or map document.

 Android retains the current generic key when the target book contains it and opens the key chooser
 only when that key is absent. A backend read failure is a third state: the switch is not applied, and
 the caller should keep its current selection visible while offering a retry.

 The value has no side effects. It reports whether content can render immediately, explicit key
 selection is required, or the preflight failed before any controller/PageManager mutation.
 */
public enum BibleReaderGenericModuleSwitchOutcome: Equatable, Sendable {
    /// The target module contains the current exact key, so content can render immediately.
    case switchedPreservingKey

    /// The target module does not contain the current key, so the caller should present its chooser.
    case switchedRequiringKeySelection

    /// SWORD could not validate the key; no module, category, key, or persistence state changed.
    case failed(message: String)
}

/**
 Internal exact-key decision used to prepare one generic module switch atomically.

 Inputs are produced by the throwing target-module key preflight. Outputs retain the exact key, mark
 explicit selection, or carry an actionable failure. The value itself has no side effects; a failed
 resolution must never be applied to controller or persisted pane state.
 */
enum BibleReaderGenericKeyResolution: Equatable {
    /// Persist and render the exact key in the target module.
    case preserve(String)
    /// Clear the invalid/missing key and request explicit selection.
    case requireSelection
    /// Abort before mutation because SWORD could not determine whether the key exists.
    case failed(message: String)

    /**
     Projects the key that successful switch application writes to controller and PageManager state.

     - Returns: The byte-exact retained key, or `nil` when explicit selection is required or preflight
       failed.
     - Side effects: None.
     - Failure modes: Failed resolutions intentionally return `nil`; callers must inspect `outcome`
       before applying a switch plan.
     */
    var retainedKey: String? {
        guard case .preserve(let key) = self else { return nil }
        return key
    }

    /**
     Projects the public result consumed by picker and quick-selector routing.

     - Returns: Immediate rendering, chooser presentation, or actionable retry failure.
     - Side effects: None.
     - Failure modes: Failure messages are preserved verbatim for localized error presentation.
     */
    var outcome: BibleReaderGenericModuleSwitchOutcome {
        switch self {
        case .preserve:
            return .switchedPreservingKey
        case .requireSelection:
            return .switchedRequiringKeySelection
        case .failed(let message):
            return .failed(message: message)
        }
    }
}

/**
 Supplies controller-owned state mutations to the module switch coordinator.

 The coordinator owns the switching rules, but the controller still owns observed reader state,
 SWORD module references, and WebView rendering. Keeping those mutations as explicit closures
 avoids making the coordinator retain a reader controller while still moving the switching workflow
 out of the large controller file.

 Inputs:
 - current SWORD manager, active window, client-ready state, and visible category snapshot
 - throwing exact-key validation and cached key enumeration used to preflight generic switches
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
    let currentDictionaryKey: String?
    let currentGeneralBookKey: String?
    let currentMapKey: String?
    /// Exact target-module lookup that distinguishes ordinary misses from backend failures.
    let containsExactGenericKey: (SwordModule, String) throws -> Bool
    /// Target-module key snapshot that proves a required chooser can load before state mutation.
    let loadGenericKeys: (SwordModule) throws -> [String]
    let setBibleModule: (SwordModule, String) -> Void
    let setCommentaryModule: (SwordModule, String) -> Void
    let setDictionaryModule: (SwordModule, String) -> Void
    let setGeneralBookModule: (SwordModule, String) -> Void
    let setMapModule: (SwordModule, String) -> Void
    let setDictionaryKey: (String?) -> Void
    let setGeneralBookKey: (String?) -> Void
    let setMapKey: (String?) -> Void
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
 - retains an exact generic entry key or clears an invalid/missing one as planned
 - optionally writes `currentCategoryName`

 Failure modes:
 - unsupported categories currently have no module-owned PageManager field, so applying them only
   updates `currentCategoryName` when requested
 */
struct BibleReaderModuleSwitchPlan: Equatable {
    let moduleName: String
    let category: DocumentCategory
    let updatesVisibleCategory: Bool
    let retainedGenericKey: String?

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
            pageManager.dictionaryKey = retainedGenericKey
        case .generalBook:
            pageManager.generalBookDocument = moduleName
            pageManager.generalBookKey = retainedGenericKey
        case .map:
            pageManager.mapDocument = moduleName
            pageManager.mapKey = retainedGenericKey
        case .epub, .dailyDevotion:
            break
        }

        guard updatesVisibleCategory else { return }
        pageManager.currentCategoryName = category.pageManagerKey
    }

    /**
     Copies a validated generic-key decision into this otherwise immutable switch plan.

     - Parameter key: Exact target-module key to preserve, or `nil` to require selection.
     - Returns: A plan with identical module/category semantics and the requested generic key.
     - Side effects: None.
     - Failure modes: None; non-generic categories ignore the key while applying the plan.
     */
    func retainingGenericKey(_ key: String?) -> BibleReaderModuleSwitchPlan {
        BibleReaderModuleSwitchPlan(
            moduleName: moduleName,
            category: category,
            updatesVisibleCategory: updatesVisibleCategory,
            retainedGenericKey: key
        )
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
     - Returns: `.switched` after successful activation, `.requiresUnlock` before any mutation when
       the encrypted target is locked, or `.unavailable` when no readable Bible target resolves.
     - Side effects: Mutates active Bible module state, refreshes the book list, persists
       `PageManager.bibleDocument`, and reloads current content when the client is ready.
     - Failure modes: Locked, missing, unsupported, and non-Bible modules leave controller,
       persistence, and rendered state unchanged.
     */
    func switchModule(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderBibleModuleSwitchOutcome {
        let mod: SwordModule
        switch readableModule(named: moduleName, context: context, logSubject: "module") {
        case .readable(let resolvedModule):
            mod = resolvedModule
        case .requiresUnlock:
            return .requiresUnlock(moduleName: moduleName)
        case .unavailable:
            return .unavailable
        }
        guard mod.info.category == .bible else {
            moduleSwitchLogger.warning(
                "Cannot switch to module \(moduleName) — expected Bible, found \(mod.info.category.rawValue)"
            )
            return .unavailable
        }

        context.setBibleModule(mod, moduleName)
        context.refreshBookList()
        moduleSwitchLogger.info("Switched to module: \(moduleName) (\(context.moduleBookListCount()) books)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .bible),
            context: context
        )

        if context.clientReady {
            context.loadCurrentContent()
        }
        return .switched
    }

    /**
     Switches the visible document to a Bible module in one Android-parity transition.

     Android's `CurrentPageManager.setCurrentDocument(book)` updates the selected Bible and active
     page together before notifying the reader. This keeps iOS on the same contract for toolbar
     quick selectors and full module-picker selections.

     - Parameters:
       - moduleName: Installed SWORD Bible module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
       - prepareForSwitch: Optional caller-owned visible-mode transition invoked after every access
         and category preflight succeeds, immediately before the existing mutation sequence.
     - Returns: `.switched` after the atomic document/category transition, `.requiresUnlock` before
       mutation for a locked target, or `.unavailable` for missing and wrong-category targets.
     - Side effects: Invokes `prepareForSwitch` only for a validated readable target, mutates active
       Bible module/category state, persists `bibleDocument` and `currentCategoryName` together, and
       reloads once when the client is ready.
     - Failure modes: Locked, missing, unsupported, and non-Bible targets leave controller,
       caller-preparation, `PageManager`, persistence, and rendered state unchanged.
     */
    func switchBibleDocument(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext,
        prepareForSwitch: (() -> Void)? = nil
    ) -> BibleReaderBibleModuleSwitchOutcome {
        let mod: SwordModule
        switch readableModule(named: moduleName, context: context, logSubject: "Bible document") {
        case .readable(let resolvedModule):
            mod = resolvedModule
        case .requiresUnlock:
            return .requiresUnlock(moduleName: moduleName)
        case .unavailable:
            return .unavailable
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .bible,
            logSubject: "Bible document"
        ) else {
            return .unavailable
        }

        prepareForSwitch?()
        context.setBibleModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        context.refreshBookList()
        moduleSwitchLogger.info("Switched to Bible document: \(moduleName) (\(context.moduleBookListCount()) books)")

        persist(plan, context: context)

        if context.clientReady {
            context.loadCurrentContent()
        }
        return .switched
    }

    /**
     Switches the selected commentary module without changing the visible document category.

     - Parameters:
       - moduleName: Installed commentary module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: `.switched` after readable activation or `.failed` before mutation.
     - Side effects: Mutates active commentary module state, persists
       `PageManager.commentaryDocument`, and reloads only when commentary is already visible.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules log and return
       `.failed` without reading keys or changing controller, persistence, or rendered state.
     */
    @discardableResult
    func switchCommentaryModule(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderCommentaryModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .commentary,
            context: context,
            logSubject: "commentary module"
        ) else {
            return .failed
        }

        context.setCommentaryModule(mod, moduleName)
        moduleSwitchLogger.info("Switched to commentary module: \(moduleName)")

        persist(
            moduleOnlySwitchPlan(moduleName: moduleName, targetCategory: .commentary),
            context: context
        )

        if context.clientReady, context.currentCategory == .commentary {
            context.loadCurrentContent()
        }
        return .switched
    }

    /**
     Switches the visible document to a commentary module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed commentary module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: `.switched` after readable activation or `.failed` before mutation.
     - Side effects: Mutates active commentary module/category state, persists
       `commentaryDocument` and `currentCategoryName` together, and reloads once when ready.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules log and return
       `.failed` without reading content or changing controller, persistence, or rendered state.
     */
    @discardableResult
    func switchCommentaryDocument(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderCommentaryModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .commentary,
            context: context,
            logSubject: "commentary document"
        ) else {
            return .failed
        }
        guard let plan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .commentary,
            logSubject: "commentary document"
        ) else {
            return .failed
        }

        context.setCommentaryModule(mod, moduleName)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to commentary document: \(moduleName)")

        persist(plan, context: context)

        if context.clientReady {
            context.loadCurrentContent()
        }
        return .switched
    }

    /**
     Switches the selected dictionary module without changing the visible document category.

     - Parameters:
       - moduleName: Installed dictionary module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active dictionary state, retains an exact target key or clears an invalid
       key, and persists the dictionary module/key fields.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchDictionaryModule(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .dictionary,
            context: context,
            logSubject: "dictionary module"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentDictionaryKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to dictionary module \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = moduleOnlySwitchPlan(
            moduleName: moduleName,
            targetCategory: .dictionary
        ).retainingGenericKey(resolution.retainedKey)
        context.setDictionaryModule(mod, moduleName)
        context.setDictionaryKey(resolution.retainedKey)
        moduleSwitchLogger.info("Switched to dictionary module: \(moduleName)")
        persist(plan, context: context)
        return resolution.outcome
    }

    /**
     Switches the visible document to a dictionary module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed dictionary module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active dictionary/category state, retains an exact target key or clears
       an invalid key, persists dictionary document/category fields together, and reloads only when
       an exact key can render immediately.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchDictionaryDocument(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .dictionary,
            context: context,
            logSubject: "dictionary document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        guard let basePlan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .dictionary,
            logSubject: "dictionary document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentDictionaryKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to dictionary document \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = basePlan.retainingGenericKey(resolution.retainedKey)
        context.setDictionaryModule(mod, moduleName)
        context.setDictionaryKey(resolution.retainedKey)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to dictionary document: \(moduleName)")
        persist(plan, context: context)

        guard context.clientReady, case .preserve = resolution else { return resolution.outcome }
        context.loadCurrentContent()
        return resolution.outcome
    }

    /**
     Switches the selected general-book module without changing the visible document category.

     - Parameters:
       - moduleName: Installed general-book module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active general-book state, retains an exact target key or clears an
       invalid key, and persists the selected module/key fields.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchGeneralBookModule(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .generalBook,
            context: context,
            logSubject: "general book module"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentGeneralBookKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to general book module \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = moduleOnlySwitchPlan(
            moduleName: moduleName,
            targetCategory: .generalBook
        ).retainingGenericKey(resolution.retainedKey)
        context.setGeneralBookModule(mod, moduleName)
        context.setGeneralBookKey(resolution.retainedKey)
        moduleSwitchLogger.info("Switched to general book module: \(moduleName)")
        persist(plan, context: context)
        return resolution.outcome
    }

    /**
     Switches the visible document to a general-book module in one Android-parity transition.

     - Parameters:
       - moduleName: Installed general-book module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active general-book/category state, retains an exact target key or
       clears an invalid key, persists document/category fields together, and reloads only when an
       exact key can render immediately.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchGeneralBookDocument(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .generalBook,
            context: context,
            logSubject: "general book document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        guard let basePlan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .generalBook,
            logSubject: "general book document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentGeneralBookKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to general book document \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = basePlan.retainingGenericKey(resolution.retainedKey)
        context.setGeneralBookModule(mod, moduleName)
        context.setGeneralBookKey(resolution.retainedKey)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to general book document: \(moduleName)")
        persist(plan, context: context)

        guard context.clientReady, case .preserve = resolution else { return resolution.outcome }
        context.loadCurrentContent()
        return resolution.outcome
    }

    /**
     Switches the selected map module without changing the visible document category.

     - Parameters:
       - moduleName: Installed map module initials to activate.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active map state, retains an exact target key or clears an invalid key,
       and persists map module/key fields.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchMapModule(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .map,
            context: context,
            logSubject: "map module"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentMapKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to map module \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = moduleOnlySwitchPlan(
            moduleName: moduleName,
            targetCategory: .map
        ).retainingGenericKey(resolution.retainedKey)
        context.setMapModule(mod, moduleName)
        context.setMapKey(resolution.retainedKey)
        moduleSwitchLogger.info("Switched to map module: \(moduleName)")
        persist(plan, context: context)
        return resolution.outcome
    }

    /**
     Switches the visible document to a map module in one Android-parity transition.

     Android's document chooser routes maps through `setCurrentDocument(book)`, so map selections
     update the selected map, retain a valid exact map key (or clear an invalid one), and switch the
     visible category as one durable page-manager write before content reload.

     - Parameters:
       - moduleName: Installed map module initials to make current.
       - context: Controller-owned state and callbacks for the active pane.
     - Returns: Whether the exact key was retained, selection is required, or validation failed.
     - Side effects: Mutates active map/category state, retains an exact target key or clears an
       invalid key, persists map document/category fields together, and reloads only when an exact
       key can render immediately.
     - Failure modes: Locked, missing, unavailable, and wrong-category modules fail before key
       inspection. Backend key failures also leave controller and persisted state unchanged.
     */
    @discardableResult
    func switchMapDocument(
        to moduleName: String,
        context: BibleReaderModuleSwitchContext
    ) -> BibleReaderGenericModuleSwitchOutcome {
        guard let mod = module(
            named: moduleName,
            expectedCategory: .map,
            context: context,
            logSubject: "map document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        guard let basePlan = validatedDocumentSwitchPlan(
            moduleName: moduleName,
            moduleCategory: mod.info.category,
            targetCategory: .map,
            logSubject: "map document"
        ) else {
            return .failed(message: "Could not switch to \(moduleName).")
        }
        let resolution = resolveGenericKey(
            currentKey: context.currentMapKey,
            containsExactKey: { try context.containsExactGenericKey(mod, $0) },
            loadKeys: { try context.loadGenericKeys(mod) }
        )
        if case .failed(let message) = resolution {
            moduleSwitchLogger.error("Cannot switch to map document \(moduleName): \(message)")
            return resolution.outcome
        }
        let plan = basePlan.retainingGenericKey(resolution.retainedKey)
        context.setMapModule(mod, moduleName)
        context.setMapKey(resolution.retainedKey)
        context.setCurrentCategory(plan.category)
        moduleSwitchLogger.info("Switched to map document: \(moduleName)")
        persist(plan, context: context)

        guard context.clientReady, case .preserve = resolution else { return resolution.outcome }
        context.loadCurrentContent()
        return resolution.outcome
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
            updatesVisibleCategory: true,
            retainedGenericKey: nil
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
            updatesVisibleCategory: false,
            retainedGenericKey: nil
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
     Resolves Android's retain-or-choose rule for a generic module switch.

     `CurrentPageBase.setCurrentDocument` keeps the current key only when the target `Book` contains
     it. The injected lookup keeps this decision independently testable while production passes
     `SwordModule.containsExactKey`, which rejects nearest-key normalization. A missing or invalid key
     preflights the target key snapshot before mutation so a backend outage cannot commit a partial
     switch; `SwordModule` caches successful snapshots for the chooser's subsequent read.

     - Parameters:
       - currentKey: Current dictionary/general-book/map key, if one is selected.
       - containsExactKey: Target-module lookup that returns true only for the identical key.
       - loadKeys: Throwing target-module snapshot loaded only when selection is required.
     - Returns: Exact key preservation, explicit selection requirement, or a failure that must abort
       the switch before state mutation.
     - Side effects: Defined by the injected operations; production temporarily moves and restores
       the target module cursor and caches only a successful immutable key snapshot.
     - Failure modes: Validation or enumeration errors become `.failed` with their localized
       description and are never treated as an absent key or a genuinely empty module.
     */
    func resolveGenericKey(
        currentKey: String?,
        containsExactKey: (String) throws -> Bool,
        loadKeys: () throws -> [String]
    ) -> BibleReaderGenericKeyResolution {
        do {
            if let currentKey,
               !currentKey.isEmpty,
               try containsExactKey(currentKey) {
                return .preserve(currentKey)
            }
            _ = try loadKeys()
            return .requireSelection
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /**
     Result of the manager-owned access preflight performed before a Bible switch mutates state.

     The readable case carries the inclusive native module handle only after the manager's fresh
     lock snapshot authorizes content access. Other cases contain no handle, preventing callers from
     accidentally reading or persisting an inaccessible module.
     */
    private enum ReadableModuleResolution {
        /// Manager-authorized native module handle ready for category validation and activation.
        case readable(SwordModule)

        /// Installed encrypted module requiring the existing passphrase workflow.
        case requiresUnlock

        /// Missing, unsupported, custom-driver, or otherwise unresolvable native module.
        case unavailable
    }

    /**
     Resolves a native module only after the manager confirms current content-read access.

     - Parameters:
       - moduleName: Installed module initials to classify and resolve.
       - context: Controller snapshot containing the active manager.
       - logSubject: Human-readable target used in diagnostics.
     - Returns: A readable module handle, an explicit unlock requirement, or unavailable state.
     - Side effects: Reads fresh manager inventory, may populate the manager's module cache, and logs
       inaccessible requests; it does not mutate controller, `PageManager`, persistence, or WebView
       state.
     - Failure modes: Missing managers, unsupported/custom projections, and native resolution races
       fail closed as `.unavailable`. Locked modules return `.requiresUnlock` without resolving them
       into the activation path.
     */
    private func readableModule(
        named moduleName: String,
        context: BibleReaderModuleSwitchContext,
        logSubject: String
    ) -> ReadableModuleResolution {
        guard let manager = context.swordManager else {
            moduleSwitchLogger.warning("Cannot switch to \(logSubject) \(moduleName) — manager unavailable")
            return .unavailable
        }
        switch manager.moduleAccessState(named: moduleName) {
        case .locked:
            moduleSwitchLogger.info("Cannot switch to \(logSubject) \(moduleName) before unlock")
            return .requiresUnlock
        case .unavailable:
            moduleSwitchLogger.warning("Cannot switch to \(logSubject) \(moduleName) — not found")
            return .unavailable
        case .readable:
            guard let module = manager.readableModule(named: moduleName) else {
                moduleSwitchLogger.warning("Cannot switch to \(logSubject) \(moduleName) — not found")
                return .unavailable
            }
            return .readable(module)
        }
    }

    /**
     Resolves a currently readable installed module for an auxiliary switch workflow.

     - Parameters:
       - moduleName: Installed module initials to resolve.
       - expectedCategory: Required auxiliary category before any key inspection or mutation.
       - context: Controller state containing the current SWORD manager.
       - logSubject: Human-readable switch target used in warning logs.
     - Returns: The manager-owned readable native handle only after fresh access and category checks.
     - Side effects: Reads installed configuration, may populate the manager cache, and logs rejected
       access; controller, persistence, keys, and rendered content remain unchanged.
     - Failure modes: Missing managers, locked/relocked modules, unavailable native handles, and
       unsupported projections or wrong-category targets return nil before any key or content read.
     */
    private func module(
        named moduleName: String,
        expectedCategory: ModuleCategory,
        context: BibleReaderModuleSwitchContext,
        logSubject: String
    ) -> SwordModule? {
        switch readableModule(named: moduleName, context: context, logSubject: logSubject) {
        case .readable(let module):
            guard module.info.category == expectedCategory else {
                moduleSwitchLogger.warning(
                    "Cannot switch to \(logSubject) \(moduleName) — expected \(expectedCategory.rawValue), found \(module.info.category.rawValue)"
                )
                return nil
            }
            return module
        case .requiresUnlock, .unavailable:
            return nil
        }
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
