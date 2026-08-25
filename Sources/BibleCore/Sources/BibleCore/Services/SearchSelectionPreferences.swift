// SearchSelectionPreferences.swift - Android-compatible persisted Search translation selection

import Foundation
import SwordKit

/**
 Identifies the Android Search flow whose translation selection is being persisted.

 Android keeps manual Bible Search and Strong's "Find all occurrences" selections under separate
 keys. The Strong's results flow also preserves its remembered order instead of moving the active
 Bible to the front.
 */
public enum SearchTranslationSelectionContext: Equatable, Sendable {
    /// Manual Bible Search backed by `search_selected_translations`.
    case standard

    /// Strong's Find All results backed by `search_results_strongs_translations`.
    case strongsFindAll

    /// Durable Android preference key owned by this Search flow.
    fileprivate var preferenceKey: AppPreferenceKey {
        switch self {
        case .standard:
            return .searchSelectedTranslations
        case .strongsFindAll:
            return .searchResultsStrongsTranslations
        }
    }

    /// Whether restore should move the active Search document to the front.
    fileprivate var prefersPrimaryModuleFirst: Bool {
        self == .standard
    }
}

/**
 Persists Search's selected Bible module abbreviations using Android's two durable preference contracts.

 Android stores a comma-separated ordered list under `search_selected_translations`. Loading drops
 modules that are no longer installed, preserves persisted order, and only moves the current module
 to the front when it is already selected. Strong's Find All instead uses
 `search_results_strongs_translations`, preserves remembered order, and receives only
 Strong's-capable installed names from its caller. An empty effective selection falls back to the
 caller-selected primary module so Search always has an eligible target.
 */
public struct SearchSelectionPreferences {
    /// Registry-backed settings store that owns the durable Android preference key.
    private let settingsStore: SettingsStore

    /**
     Creates a Search-selection store on the same SwiftData backend as Android-compatible settings.

     - Parameter settingsStore: Registry-aware settings store used for all reads and writes.
     - Side effects: none during initialization.
     - Failure modes: Persistence failures are handled by `SettingsStore` consistently with other
       application preferences.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Loads the persisted module order against the currently installed module set.

     - Parameters:
       - installedModuleNames: Installed Bible abbreviations that remain valid search targets.
       - primaryModuleName: Current reader module, preferred first only when selected.
       - context: Search flow that selects the durable key and primary-ordering behavior.
     - Returns: Valid selected modules in persisted order, or the installed primary module when no
       persisted selection survives.
     - Side effects: Reads the registry-backed SwiftData setting.
     - Failure modes: Malformed, duplicate, blank, and uninstalled values are discarded.
     */
    public func loadSelection(
        installedModuleNames: [String],
        primaryModuleName: String?,
        context: SearchTranslationSelectionContext = .standard
    ) -> [String] {
        let installed = SwordJavaExactStringSet(installedModuleNames)
        let rawValue = settingsStore.getString(context.preferenceKey)
        var seen = SwordJavaExactStringSet()
        var selected = rawValue
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && installed.contains($0) && seen.insert($0) }

        if selected.isEmpty,
           let primaryModuleName,
           installed.contains(primaryModuleName) {
            selected = [primaryModuleName]
        } else if context.prefersPrimaryModuleFirst,
                  let primaryModuleName,
                  let primaryIndex = selected.firstIndex(where: {
                      SwordJavaStringIdentity.equals($0, primaryModuleName)
                  }),
                  primaryIndex != 0 {
            selected.remove(at: primaryIndex)
            selected.insert(primaryModuleName, at: 0)
        }
        return selected
    }

    /**
     Saves a non-empty ordered module selection with the selected Android flow's CSV encoding.

     - Parameters:
       - orderedModuleNames: Effective selected module order after flow-specific ordering.
       - context: Search flow whose durable selection should be updated.
     - Side effects: Writes `SettingsStore` and removes duplicates while preserving first occurrence.
     - Failure modes: Empty input leaves the prior preference untouched, matching Android's ignored
       empty picker result.
     */
    public func saveSelection(
        _ orderedModuleNames: [String],
        context: SearchTranslationSelectionContext = .standard
    ) {
        var seen = SwordJavaExactStringSet()
        let normalized = orderedModuleNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0) }
        guard !normalized.isEmpty else { return }
        settingsStore.setString(context.preferenceKey, value: normalized.joined(separator: ","))
    }
}
