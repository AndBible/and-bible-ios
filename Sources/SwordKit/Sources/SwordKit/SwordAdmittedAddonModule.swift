// SwordAdmittedAddonModule.swift — Shared Android add-on admission projection

import Foundation

/**
 One installed add-on admitted by Android's shared add-on feature contract.

 Android prompt packs, reading plans, and the Add-ons document picker begin with the same
 `AndBibleAddonFilter` view of `Books.installed()`. This immutable value exposes the metadata needed
 by prompt and picker consumers without letting either surface repeat compatibility or ordering
 decisions. Font discovery remains separately tracked until it joins this projection.
 */
public struct SwordAdmittedAddonModule: Sendable {
    /// Installed-book metadata in pinned JSword TreeSet order.
    public let moduleInfo: ModuleInfo

    /// JSword abbreviation used by Android's chooser and installed-book ordering.
    public let abbreviation: String

    /// First case-sensitive `AndBibleProvidesPrompts` value, or nil when the add-on has no pack.
    public let promptFileName: String?

    /// Filesystem-adjusted JSword book location, or nil when JSword retained no location.
    public let locationURL: URL?

    /// Exact config or standalone-CSV owner used by Android-equivalent uninstall routing.
    public let removalTarget: SwordInstalledAddonRemovalTarget

    /**
     Creates one already-admitted add-on projection.

     - Parameters:
       - moduleInfo: Supported installed add-on metadata after HashSet and TreeSet replay.
       - abbreviation: Java-trimmed JSword abbreviation used by Android document sorting.
       - promptFileName: Singular first prompt-pack property matching JSword `getProperty`.
       - locationURL: Validated adjusted book location matching JSword directory/file-prefix rules,
         or nil when a slashless `DataPath` leaves JSword metadata without a feature location.
       - removalTarget: Opaque installed owner revalidated by the mutation boundary during delete.
     - Side effects: None.
     - Failure modes: None; construction is internal to the shared admission pipeline.
     */
    init(
        moduleInfo: ModuleInfo,
        abbreviation: String,
        promptFileName: String?,
        locationURL: URL?,
        removalTarget: SwordInstalledAddonRemovalTarget
    ) {
        self.moduleInfo = moduleInfo
        self.abbreviation = abbreviation
        self.promptFileName = promptFileName
        self.locationURL = locationURL
        self.removalTarget = removalTarget
    }
}
