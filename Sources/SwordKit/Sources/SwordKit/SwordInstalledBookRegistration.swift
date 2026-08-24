// SwordInstalledBookRegistration.swift — Installed JSword metadata with comparator fields

/**
 One installed book exposed with the metadata Android's chooser and BookSet consumers require.

 `ModuleInfo.name` is the exact initials identity, while `abbreviation` is the independently parsed
 JSword display/comparator field. Keeping both prevents UI and feature consumers from reconstructing
 abbreviation from initials after installed HashSet/TreeSet ownership has already been resolved.
 */
public struct SwordInstalledBookRegistration: Sendable {
    /// Inclusive installed metadata, including current encrypted/unlocked access state.
    public let moduleInfo: ModuleInfo

    /// Java-trimmed JSword abbreviation with exact initials fallback already applied.
    public let abbreviation: String

    /**
     Creates one installed registration from the shared manager snapshot.

     - Parameters:
       - moduleInfo: Installed owner metadata after payload and BookSet admission.
       - abbreviation: Exact JSword abbreviation used by Android display and sorting.
     - Side effects: None.
     - Failure modes: None; construction is internal to `SwordManager`'s admitted projection.
     */
    init(moduleInfo: ModuleInfo, abbreviation: String) {
        self.moduleInfo = moduleInfo
        self.abbreviation = abbreviation
    }
}
