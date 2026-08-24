// SearchTranslationPickerDraftState.swift -- Android Search translation dialog draft state

import Foundation
import SwordKit

/**
 Pure state reducer for Android-style Search translation picker interactions.

 Android's multiselect dialog edits a temporary checked-row set while the dialog is open. Cancel
 and outside dismiss discard that draft, while OK commits only non-empty selections. Keeping this
 behavior in a small value type lets package tests protect the contract without adding another
 launched-app Search smoke.
 */
struct SearchTranslationPickerDraftState: Equatable {
    /// Whether the translation picker overlay is currently presented.
    var isPresented: Bool

    /// Temporary selected module abbreviations while the picker is presented.
    var pendingSelection: SwordJavaExactStringSet

    /**
     Creates a draft state value.

     - Parameters:
       - isPresented: Whether the picker overlay should be visible.
       - pendingSelection: Temporary selected module abbreviations.
     - Returns: A draft state value.
     - Side effects: None.
     - Failure modes: None.
     */
    init(isPresented: Bool = false, pendingSelection: SwordJavaExactStringSet = []) {
        self.isPresented = isPresented
        self.pendingSelection = pendingSelection
    }

    /**
     Opens the picker with Android's prechecked-row ordering.

     - Parameters:
       - selectedModuleNames: Current committed Search module abbreviations.
       - primaryModuleName: Current reader/search module abbreviation, preferred first.
       - installedModules: Installed Bible modules used for Android abbreviation ordering.
     - Returns: Presented draft state seeded from the committed selection.
     - Side effects: None.
     - Failure modes: Empty inputs produce an empty draft; OK will later preserve the previous
       committed selection through `committedSelection(...)`.
     */
    static func opened(
        selectedModuleNames: SwordJavaExactStringSet,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> SearchTranslationPickerDraftState {
        SearchTranslationPickerDraftState(
            isPresented: true,
            pendingSelection: SwordJavaExactStringSet(SearchTranslationSelectionPolicy.orderedSelection(
                selectedModuleNames: selectedModuleNames,
                primaryModuleName: primaryModuleName,
                installedModules: installedModules
            ))
        )
    }

    /**
     Returns the Android Cancel/outside-dismiss result.

     - Returns: A dismissed state with no retained draft selection.
     - Side effects: None.
     - Failure modes: None.
     */
    func cancelled() -> SearchTranslationPickerDraftState {
        SearchTranslationPickerDraftState()
    }

    /**
     Toggles one draft module abbreviation.

     - Parameter moduleName: Module abbreviation for the tapped row.
     - Returns: A presented state with the row toggled. The draft may become empty because Android
       permits an empty checked set while the dialog remains open.
     - Side effects: None.
     - Failure modes: None.
     */
    func toggled(_ moduleName: String) -> SearchTranslationPickerDraftState {
        var nextSelection = pendingSelection
        if nextSelection.contains(moduleName) {
            nextSelection.remove(moduleName)
        } else {
            nextSelection.insert(moduleName)
        }
        return SearchTranslationPickerDraftState(
            isPresented: isPresented,
            pendingSelection: nextSelection
        )
    }

    /**
     Applies Android's neutral Select all/none action.

     - Parameter moduleNames: All visible picker module abbreviations in Android row order.
     - Returns: A presented state with all rows selected, or none when all rows were already
       selected.
     - Side effects: None.
     - Failure modes: Empty module lists leave the draft empty.
     */
    func toggledAll(moduleNames: [String]) -> SearchTranslationPickerDraftState {
        let allModuleNames = SwordJavaExactStringSet(moduleNames)
        let hasEveryVisibleModule = !allModuleNames.isEmpty
            && allModuleNames.values.allSatisfy(pendingSelection.contains)
        let nextSelection: SwordJavaExactStringSet = hasEveryVisibleModule ? [] : allModuleNames
        return SearchTranslationPickerDraftState(
            isPresented: isPresented,
            pendingSelection: nextSelection
        )
    }

    /**
     Resolves the OK action into committed Search modules and dismissed draft state.

     - Parameters:
       - previousModuleNames: Existing committed Search module abbreviations.
       - primaryModuleName: Current reader/search module abbreviation, preferred first.
       - installedModules: Installed Bible modules used for Android abbreviation ordering.
     - Returns: Ordered committed module abbreviations plus a dismissed draft state. Empty drafts
       preserve the previous committed selection through Android's empty-result contract.
     - Side effects: None.
     - Failure modes: None.
     */
    func committedSelection(
        previousModuleNames: SwordJavaExactStringSet,
        primaryModuleName: String?,
        installedModules: [ModuleInfo]
    ) -> (orderedModuleNames: [String], draftState: SearchTranslationPickerDraftState) {
        let orderedSelection = SearchTranslationSelectionPolicy.committedSelection(
            previousModuleNames: previousModuleNames,
            draftModuleNames: pendingSelection,
            primaryModuleName: primaryModuleName,
            installedModules: installedModules
        )
        return (orderedSelection, SearchTranslationPickerDraftState())
    }
}
