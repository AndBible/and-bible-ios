// BibleReaderSwordCoordinator.swift -- SWORD setup and module-state projection for reader panes

import BibleCore
import SwordKit

/**
 Current controller-owned SWORD module selections.

 The setup coordinator uses these initials as inputs when rebuilding module handles from a
 `SwordManager`. The value keeps selection identity separate from `SwordModule` instances so pane
 controllers can resolve independent module cursors from a shared manager while preserving Android's
 category-owned document fields.
 */
struct BibleReaderSwordSelection {
    /// Preferred Bible module initials. The controller keeps `"KJV"` as its default seed.
    let activeModuleName: String

    /// Preferred commentary module initials, if the pane has one selected.
    let activeCommentaryModuleName: String?

    /// Preferred dictionary module initials, if the pane has one selected.
    let activeDictionaryModuleName: String?

    /// Preferred general-book module initials, if the pane has one selected.
    let activeGeneralBookModuleName: String?

    /// Preferred map module initials, if the pane has one selected.
    let activeMapModuleName: String?
}

/**
 Result of configuring a reader pane against a SWORD manager.

 This projection contains the installed-module catalog, resolved active module handles, selected
 module initials, and active Bible book list that the controller publishes to SwiftUI and the Vue
 bridge. It is a copied snapshot of SWORD-derived state; the controller remains responsible for
 storing it and for logging or rendering follow-up work.
 */
struct BibleReaderSwordState {
    /// Flat installed-module list used for setup logging and diagnostics.
    let installedModules: [ModuleInfo]

    /// Installed Bible modules shown in Bible pickers.
    let installedBibleModules: [ModuleInfo]

    /// Installed commentary modules shown in commentary/document pickers.
    let installedCommentaryModules: [ModuleInfo]

    /// Installed dictionary modules shown in dictionary/document pickers.
    let installedDictionaryModules: [ModuleInfo]

    /// Installed general-book modules shown in document pickers.
    let installedGeneralBookModules: [ModuleInfo]

    /// Installed map modules shown in map/document pickers.
    let installedMapModules: [ModuleInfo]

    /// Active readable Bible handle, or nil when no installed Bible is currently readable.
    let activeModule: SwordModule?

    /// Active Bible module initials to persist and display.
    let activeModuleName: String

    /// Active commentary module handle, if selected or defaulted.
    let activeCommentaryModule: SwordModule?

    /// Active commentary module initials, preserved even if the module is temporarily unavailable.
    let activeCommentaryModuleName: String?

    /// Active dictionary module handle, if explicitly selected and installed.
    let activeDictionaryModule: SwordModule?

    /// Active dictionary module initials, preserved even if the module is temporarily unavailable.
    let activeDictionaryModuleName: String?

    /// Active general-book module handle, if explicitly selected and installed.
    let activeGeneralBookModule: SwordModule?

    /// Active general-book module initials, preserved even if the module is temporarily unavailable.
    let activeGeneralBookModuleName: String?

    /// Active map module handle, if explicitly selected and installed.
    let activeMapModule: SwordModule?

    /// Active map module initials, preserved even if the module is temporarily unavailable.
    let activeMapModuleName: String?

    /// Ordered Bible book list from the active module's SWORD/JSword-compatible versification.
    let moduleBookList: [BookInfo]
}

/**
 Owns SWORD manager setup rules for `BibleReaderController`.

 The coordinator applies global SWORD rendering options, splits installed modules by Android
 document category, resolves category-specific active module handles, and reads the active Bible
 book list. It does not retain the controller, mutate `PageManager`, or emit bridge events; those
 side effects remain in the controller and existing module/navigation coordinators.
 */
struct BibleReaderSwordCoordinator {
    /**
     Builds a complete reader SWORD state projection from a manager and prior selections.

     - Parameters:
       - manager: Shared `SwordManager` whose modules should back the reader pane.
       - selection: Previously selected module initials owned by the pane controller.
       - displaySettings: Resolved reader settings used to configure SWORD filters.
       - defaults: Application defaults used when a setting is unset.
     - Returns: Installed-module catalog, resolved module handles, selected initials, and active
       module book list.
     - Side effects: Sets SWORD global options on `manager`.
     - Failure modes: Missing or locked modules produce nil handles while preserving selected
       initials; no readable Bible produces an empty book list instead of static-canon fallback.
     */
    func configure(
        manager: SwordManager,
        selection: BibleReaderSwordSelection,
        displaySettings: TextDisplaySettings,
        defaults: TextDisplaySettings = .appDefaults
    ) -> BibleReaderSwordState {
        applyBaseOptions(to: manager)
        applyDisplayOptions(to: manager, settings: displaySettings, defaults: defaults)

        // `installedModules()` already excludes unsupported modules (e.g. an unknown-versification
        // Bible), mirroring Android's `Books.installed()`, so partitioning by category is sufficient.
        let modules = manager.installedModules()
        let bibleModules = modules.filter { $0.category == .bible }
        let commentaryModules = modules.filter { $0.category == .commentary }
        let dictionaryModules = modules.filter { $0.category == .dictionary }
        let generalBookModules = modules.filter { $0.category == .generalBook }
        let mapModules = modules.filter { $0.category == .map }

        let bible = activeBibleModule(
            manager: manager,
            requestedName: selection.activeModuleName,
            installedBibleModules: bibleModules
        )
        let commentary = activeCommentaryModule(
            manager: manager,
            requestedName: selection.activeCommentaryModuleName,
            installedCommentaryModules: commentaryModules
        )
        let dictionary = activeOptionalModule(
            manager: manager,
            requestedName: selection.activeDictionaryModuleName,
            installedModules: dictionaryModules
        )
        let generalBook = activeOptionalModule(
            manager: manager,
            requestedName: selection.activeGeneralBookModuleName,
            installedModules: generalBookModules
        )
        let map = activeOptionalModule(
            manager: manager,
            requestedName: selection.activeMapModuleName,
            installedModules: mapModules
        )

        return BibleReaderSwordState(
            installedModules: modules,
            installedBibleModules: bibleModules,
            installedCommentaryModules: commentaryModules,
            installedDictionaryModules: dictionaryModules,
            installedGeneralBookModules: generalBookModules,
            installedMapModules: mapModules,
            activeModule: bible.module,
            activeModuleName: bible.name,
            activeCommentaryModule: commentary.module,
            activeCommentaryModuleName: commentary.name,
            activeDictionaryModule: dictionary.module,
            activeDictionaryModuleName: selection.activeDictionaryModuleName,
            activeGeneralBookModule: generalBook.module,
            activeGeneralBookModuleName: selection.activeGeneralBookModuleName,
            activeMapModule: map.module,
            activeMapModuleName: selection.activeMapModuleName,
            moduleBookList: bookList(for: bible.module)
        )
    }

    /**
     Applies SWORD options that the reader always expects before rendering.

     - Parameter manager: Manager whose global options should be updated.
     - Side effects: Enables SWORD headings and red-letter rendering.
     - Failure modes: None surfaced by SwordKit; SWORD option writes are process-global.
     */
    func applyBaseOptions(to manager: SwordManager) {
        manager.setGlobalOption(.headings, enabled: true)
        manager.setGlobalOption(.redLetterWords, enabled: true)
    }

    /**
     Applies display-setting-driven SWORD filter options.

     - Parameters:
       - manager: Manager whose global options should be updated.
       - settings: Resolved reader settings for the pane.
       - defaults: Fallback settings used when a value is unset.
     - Side effects: Mutates SWORD global options for Strong's numbers, morphology, footnotes, and
       cross references.
     - Failure modes: None surfaced by SwordKit; SWORD option writes are process-global.
     */
    func applyDisplayOptions(
        to manager: SwordManager,
        settings: TextDisplaySettings,
        defaults: TextDisplaySettings = .appDefaults
    ) {
        let xrefsOn = settings.showXrefs ?? defaults.showXrefs ?? false
        let footnotesOn = settings.showFootNotes ?? defaults.showFootNotes ?? false
        manager.setGlobalOption(.strongsNumbers, enabled: true)
        manager.setGlobalOption(.morphology, enabled: settings.showMorphology ?? defaults.showMorphology ?? false)
        manager.setGlobalOption(.footnotes, enabled: footnotesOn)
        manager.setGlobalOption(.crossReferences, enabled: xrefsOn)
    }

    /**
     Reads the active Bible module's versification book list.

     - Parameter module: Active readable Bible module handle, or nil when no installed Bible is
       currently readable.
     - Returns: SWORD-provided ordered books, or an empty list when no module is active or the module
       reports no books.
     - Side effects: Calls into SWORD through `SwordModule.getBookList()`.
     - Failure modes: Empty SWORD results are propagated as empty so callers do not silently fall
       back to a static canon while an active module exists.
     */
    func bookList(for module: SwordModule?) -> [BookInfo] {
        module?.getBookList() ?? []
    }

    /**
     Resolves the active readable Bible using the controller's historical fallback order.

     - Parameters:
       - manager: Manager used for module lookup.
       - requestedName: Previously selected Bible initials.
       - installedBibleModules: Installed Bible catalog used for first-installed fallback.
     - Returns: A module/name pair selected from readable requested, KJV, or first-installed
       candidates. If only locked or unavailable Bibles exist, the returned module is nil and the
       requested name is preserved while the app-owned startup queue processes every initially
       locked Bible; blocking setup follows only if final fresh inventory remains unreadable.
     - Side effects: Resolves one native handle only after the caller's single fresh,
       session-adjusted inventory snapshot classifies its selected row readable.
     - Failure modes: Locked modules are retained in installed inventory but never returned as the
       active reader backend. Missing and unsupported modules continue through the fallback order.
     */
    private func activeBibleModule(
        manager: SwordManager,
        requestedName: String,
        installedBibleModules: [ModuleInfo]
    ) -> (module: SwordModule?, name: String) {
        let nativeOwner: (String) -> ModuleInfo? = { name in
            installedBibleModules.first { info in
                !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info)
                    && SwordJavaStringIdentity.equalsIgnoreCase(info.name, name)
            }
        }
        let isReadable: (ModuleInfo) -> Bool = { info in
            !info.isEncrypted || info.isUnlocked
        }

        let selected: ModuleInfo?
        if let requested = nativeOwner(requestedName), isReadable(requested) {
            selected = requested
        } else if let kjv = nativeOwner("KJV"), isReadable(kjv) {
            selected = kjv
        } else if let first = installedBibleModules.first(where: { info in
            !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) && isReadable(info)
        }) {
            selected = first
        } else {
            selected = nil
        }

        guard let selected,
              let module = manager.module(named: selected.name) else {
            return (nil, requestedName)
        }
        return (module, selected.name)
    }

    /**
     Resolves commentary selection with the existing first-installed fallback.

     - Parameters:
       - manager: Manager used for module lookup.
       - requestedName: Previously selected commentary initials.
       - installedCommentaryModules: Installed commentary catalog used for fallback.
     - Returns: A commentary module/name pair, preserving the requested initials when no fallback is
       available.
     - Side effects: Resolves at most one native handle after the caller's existing fresh inventory
       snapshot classifies the selected or fallback row readable.
     - Failure modes: Locked and missing requested rows continue to the first readable commentary;
       if no readable row exists, the requested initials are preserved with a nil handle.
     */
    private func activeCommentaryModule(
        manager: SwordManager,
        requestedName: String?,
        installedCommentaryModules: [ModuleInfo]
    ) -> (module: SwordModule?, name: String?) {
        let isReadable: (ModuleInfo) -> Bool = { info in
            !info.isEncrypted || info.isUnlocked
        }
        if let requestedName,
           let requested = installedCommentaryModules.first(where: {
               SwordJavaStringIdentity.equalsIgnoreCase($0.name, requestedName)
           }),
           isReadable(requested),
           let module = manager.module(named: requested.name) {
            return (module, requestedName)
        }
        if let firstCommentary = installedCommentaryModules.first(where: isReadable),
           let module = manager.module(named: firstCommentary.name) {
            return (module, firstCommentary.name)
        }
        return (nil, requestedName)
    }

    /**
     Resolves optional auxiliary module selections without inventing defaults.

     Dictionaries, general books, and maps are only active when a pane has selected one. Android's
     durable page-manager fields keep those choices category-specific, so this helper preserves the
     requested initials while returning a nil handle if the module is absent or locked.

     - Parameters:
       - manager: Manager used only to resolve the canonical readable row's native handle.
       - requestedName: Persisted category-specific initials, or nil when no source was selected.
       - installedModules: The category slice from the caller's single fresh inventory snapshot.
     - Returns: A readable native handle plus the unchanged requested state, or a nil handle while
       preserving that state when the row is missing or locked.
     - Side effects: Resolves at most one native handle after snapshot authorization.
     - Failure modes: Missing, locked, and native-resolution failures return a nil handle; no
       fallback module is invented.
     */
    private func activeOptionalModule(
        manager: SwordManager,
        requestedName: String?,
        installedModules: [ModuleInfo]
    ) -> (module: SwordModule?, name: String?) {
        guard let requestedName else { return (nil, nil) }
        guard let selected = installedModules.first(where: {
            SwordJavaStringIdentity.equalsIgnoreCase($0.name, requestedName)
        }),
              !selected.isEncrypted || selected.isUnlocked,
              let module = manager.module(named: selected.name) else {
            return (nil, requestedName)
        }
        return (module, requestedName)
    }
}
