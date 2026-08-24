// SearchTranslationSelectionPolicy.swift -- Android Search document-selection rules

import SwordKit

/**
 Resolves the installed modules, fallback document, and execution order for Android Search flows.

 Manual Search may use every installed Bible and retains its existing primary-first behavior in
 `SearchView`. Strong's Find All is narrower: only modules advertising `StrongsNumbers` are eligible,
 a Strong's-capable current Bible wins, and otherwise Android prefers an already indexed eligible
 Bible before the first installed eligible Bible.

 This policy performs no persistence or module I/O. Callers supply index readiness as a synchronous
 snapshot so tests and UI state resolution remain deterministic.
 */
enum SearchTranslationSelectionPolicy {
    /**
     Sorts and de-duplicates Search translation modules using Android's initials-backed row order.

     Android builds the translation multiselect in abbreviation order. At this boundary
     `ModuleInfo.name` is the installed initials fallback retained by the Search inventory. Exact
     duplicate initials are emitted once because persisted selection is initials-keyed, while
     NFC/NFD and case variants remain independent.

     - Parameter modules: Installed Bible modules available to Search.
     - Returns: Deterministic row order with one module per exact UTF-16 initials identity.
     - Side effects: None.
     - Failure modes: None; empty input returns an empty array.
     */
    static func androidSortedModules(_ modules: [ModuleInfo]) -> [ModuleInfo] {
        var seen = SwordJavaExactStringSet()
        return modules.enumerated().sorted { lhs, rhs in
            let lhsUnits = SwordJavaExactStringIdentity(lhs.element.name).utf16CodeUnits
            let rhsUnits = SwordJavaExactStringIdentity(rhs.element.name).utf16CodeUnits
            if lhsUnits != rhsUnits {
                return lhsUnits.lexicographicallyPrecedes(rhsUnits)
            }
            return lhs.offset < rhs.offset
        }.compactMap { entry in
            seen.insert(entry.element.name) ? entry.element : nil
        }
    }

    /**
     Resolves selected Search module names in Android commit/search order.

     Android collects selected rows from its ordered dialog and moves the current document to the
     front with `ensurePrimaryDocumentFirst()`. Unknown persisted names remain after installed rows
     in deterministic Java UTF-16 order so schema-preserved selections do not depend on set order.

     - Parameters:
       - selectedModuleNames: Committed exact module initials selected for Search.
       - primaryModuleName: Current reader/search initials, preferred first when selected.
       - installedModules: Installed Bible modules used to derive dialog order.
     - Returns: Selected initials with the primary first and each exact identity emitted once.
     - Side effects: None.
     - Failure modes: Empty selection and a missing primary return an empty array.
     */
    static func orderedSelection(
        selectedModuleNames: SwordJavaExactStringSet,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        var effectiveSelection = selectedModuleNames
        if effectiveSelection.isEmpty, let primaryModuleName {
            effectiveSelection.insert(primaryModuleName)
        }

        var orderedNames = androidSortedModules(installedModules)
            .map(\.name)
            .filter { effectiveSelection.contains($0) }
        orderedNames.append(contentsOf: effectiveSelection.subtracting(orderedNames).values)

        if let primaryModuleName,
           let primaryIndex = orderedNames.firstIndex(where: {
               SwordJavaStringIdentity.equals($0, primaryModuleName)
           }) {
            orderedNames.remove(at: primaryIndex)
            orderedNames.insert(primaryModuleName, at: 0)
        }
        return orderedNames
    }

    /**
     Applies Android's non-empty Search translation dialog commit rule.

     - Parameters:
       - previousModuleNames: Selection committed before the dialog opened.
       - draftModuleNames: Exact checked identities in the current dialog draft.
       - primaryModuleName: Current reader/search initials, preferred first.
       - installedModules: Installed Bible modules used to derive dialog order.
     - Returns: Ordered draft selection, or the previous selection when the draft is empty.
     - Side effects: None.
     - Failure modes: If previous and draft selections and the primary are absent, returns empty.
     */
    static func committedSelection(
        previousModuleNames: SwordJavaExactStringSet,
        draftModuleNames: SwordJavaExactStringSet,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> [String] {
        orderedSelection(
            selectedModuleNames: draftModuleNames.isEmpty ? previousModuleNames : draftModuleNames,
            primaryModuleName: primaryModuleName,
            installedModules: installedModules
        )
    }

    /**
     Filters the installed Bible inventory for one Search presentation.

     - Parameters:
       - installedModules: Installed Bible metadata in manager order.
       - isStrongsFindAll: Whether Search was opened from Strong's Find All.
     - Returns: Every installed module for manual Search, or only Strong's-capable modules for Find All.
     - Side effects: None.
     - Failure modes: An empty or entirely ineligible inventory returns an empty array.
     */
    static func candidateModules(
        from installedModules: [ModuleInfo],
        isStrongsFindAll: Bool
    ) -> [ModuleInfo] {
        guard isStrongsFindAll else { return installedModules }
        return installedModules.filter { $0.features.contains(.strongsNumbers) }
    }

    /**
     Chooses Android's fallback Search document when no remembered selection remains valid.

     - Parameters:
       - currentModuleName: Initials of the Bible active when Search opened.
       - candidateModules: Modules already filtered for the Search presentation.
       - isStrongsFindAll: Whether Search was opened from Strong's Find All.
       - isIndexed: Snapshot lookup for completed text-index readiness.
     - Returns: The active eligible Bible, otherwise Android's indexed-first Strong's fallback, or
       `nil` when no eligible Bible exists.
     - Side effects: Calls `isIndexed` only for Strong's fallback candidates after rejecting an
       ineligible current module.
     - Failure modes: Missing current metadata and an empty candidate list return `nil`.
     - Note: Candidate order is retained for equal index status, matching Android's stable sort of
       `SwordDocumentFacade.bibles`.
     */
    static func fallbackModuleName(
        currentModuleName: String?,
        candidateModules: [ModuleInfo],
        isStrongsFindAll: Bool,
        isIndexed: (String) -> Bool
    ) -> String? {
        if let currentModuleName,
           candidateModules.contains(where: {
               SwordJavaStringIdentity.equals($0.name, currentModuleName)
           }) {
            return currentModuleName
        }
        guard isStrongsFindAll else { return nil }
        return candidateModules.first(where: { isIndexed($0.name) })?.name
            ?? candidateModules.first?.name
    }

    /**
     Restores Strong's Find All execution order without applying manual Search's primary-first rule.

     Android preserves the order stored under `search_results_strongs_translations`. Picker commits
     are abbreviation-sorted, while a restored preference may retain an older valid order. This
     helper keeps the remembered eligible prefix and appends any selected modules absent from that
     prefix in Android picker order.

     - Parameters:
       - selectedModuleNames: Effective selected module initials.
       - rememberedOrder: Ordered initials loaded from Strong's-specific persistence.
       - candidateModules: Strong's-capable installed modules.
     - Returns: Eligible selected initials in remembered order followed by abbreviation order.
     - Side effects: None.
     - Failure modes: Ineligible, uninstalled, blank, and duplicate names are omitted. An empty
       effective selection returns an empty array for the caller to surface explicitly.
     */
    static func strongsOrderedSelection(
        selectedModuleNames: SwordJavaExactStringSet,
        rememberedOrder: [String],
        candidateModules: [ModuleInfo]
    ) -> [String] {
        let eligibleNames = SwordJavaExactStringSet(candidateModules.map(\.name))
        var seen = SwordJavaExactStringSet()
        var ordered = rememberedOrder.filter {
            selectedModuleNames.contains($0)
                && eligibleNames.contains($0)
                && seen.insert($0)
        }
        ordered.append(contentsOf: androidSortedModules(candidateModules)
            .map(\.name)
            .filter {
                selectedModuleNames.contains($0)
                    && seen.insert($0)
            })
        return ordered
    }
}
