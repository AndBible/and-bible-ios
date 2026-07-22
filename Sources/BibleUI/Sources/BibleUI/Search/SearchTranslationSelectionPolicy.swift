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
           candidateModules.contains(where: { $0.name == currentModuleName }) {
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
        selectedModuleNames: Set<String>,
        rememberedOrder: [String],
        candidateModules: [ModuleInfo]
    ) -> [String] {
        let eligibleNames = Set(candidateModules.map(\.name))
        var seen = Set<String>()
        var ordered = rememberedOrder.filter {
            selectedModuleNames.contains($0)
                && eligibleNames.contains($0)
                && seen.insert($0).inserted
        }
        ordered.append(contentsOf: candidateModules
            .sorted { $0.name < $1.name }
            .map(\.name)
            .filter {
                selectedModuleNames.contains($0)
                    && seen.insert($0).inserted
            })
        return ordered
    }
}
