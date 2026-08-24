// SwordAdmittedAddonModule.swift — Shared Android add-on admission projection

import Foundation

/**
 One installed add-on admitted by Android's shared add-on feature contract.

 Android prompt packs, reading plans, fonts, and the Add-ons document picker begin with the same
 `AndBibleAddonFilter` view of `Books.installed()`. This immutable value exposes the metadata needed
 by feature consumers without letting any surface repeat compatibility or ordering decisions.
 */
public struct SwordAdmittedAddonModule: Sendable {
    /// Installed-book metadata in pinned JSword TreeSet order.
    public let moduleInfo: ModuleInfo

    /// JSword abbreviation used by Android's chooser and installed-book ordering.
    public let abbreviation: String

    /// First case-sensitive `AndBibleProvidesPrompts` value, or nil when the add-on has no pack.
    public let promptFileName: String?

    /// Readable, contained fonts supplied by this exact installed add-on owner.
    public let providedFonts: [SwordAdmittedFont]

    /**
     Readable font files reserved by this installed metadata row even when exact initials ownership
     is ambiguous and the row therefore cannot publish a font provider.

     The manual-TTF synthesizer consumes this internal set so an ambiguous config-backed file cannot
     reappear as a generated standalone font and bypass the shared fail-closed owner decision.
    */
    let reservedFontFileURLs: [URL]

    /// Whether this unambiguous admitted owner carries Android's font-provider marker.
    public let providesFont: Bool

    /// Whether this admitted owner supplies Android's WebView feature bundle marker.
    public let providesWebFeature: Bool

    /// Whether this admitted owner supplies Android's WebView style bundle marker.
    public let providesWebStyle: Bool

    /// Filesystem-adjusted JSword book location, or nil when JSword retained no location.
    public let locationURL: URL?

    /// Exact config or standalone-CSV owner used by Android-equivalent uninstall routing.
    public let removalTarget: SwordInstalledAddonRemovalTarget

    /// Whether iOS persisted this row for Android's configless manually installed TTF book.
    let isManualTtfRegistration: Bool

    /**
     Creates one already-admitted add-on projection.

     - Parameters:
       - moduleInfo: Supported installed add-on metadata after HashSet and TreeSet replay.
       - abbreviation: Java-trimmed JSword abbreviation used by Android document sorting.
       - promptFileName: Singular first prompt-pack property matching JSword `getProperty`.
       - providedFonts: Validated readable font providers from every repeated metadata value.
       - reservedFontFileURLs: Validated readable provider files that remain config-owned even when
         ambiguous exact initials prevent them from being published.
       - providesFont: Whether an unambiguous owner carries `AndBibleProvidesFont`, matching
         Android's reload inventory even when an individual provider file is unreadable.
       - providesWebFeature: Whether `AndBibleProvidesFeature` exists on the installed owner.
       - providesWebStyle: Whether `AndBibleProvidesStyle` exists on the installed owner.
       - locationURL: Validated adjusted book location matching JSword directory/file-prefix rules,
         or nil when a slashless `DataPath` leaves JSword metadata without a feature location.
       - removalTarget: Opaque installed owner revalidated by the mutation boundary during delete.
       - isManualTtfRegistration: Whether this is iOS' durable representation of Android's
         configless manually installed TTF book.
     - Side effects: None.
     - Failure modes: None; construction is internal to the shared admission pipeline.
     */
    init(
        moduleInfo: ModuleInfo,
        abbreviation: String,
        promptFileName: String?,
        providedFonts: [SwordAdmittedFont],
        reservedFontFileURLs: [URL],
        providesFont: Bool,
        providesWebFeature: Bool,
        providesWebStyle: Bool,
        locationURL: URL?,
        removalTarget: SwordInstalledAddonRemovalTarget,
        isManualTtfRegistration: Bool
    ) {
        self.moduleInfo = moduleInfo
        self.abbreviation = abbreviation
        self.promptFileName = promptFileName
        self.providedFonts = providedFonts
        self.reservedFontFileURLs = reservedFontFileURLs
        self.providesFont = providesFont
        self.providesWebFeature = providesWebFeature
        self.providesWebStyle = providesWebStyle
        self.locationURL = locationURL
        self.removalTarget = removalTarget
        self.isManualTtfRegistration = isManualTtfRegistration
    }
}

/**
 One readable font claimed by an exact owner in the shared admitted add-on projection.

 Android builds both font settings and WebView font CSS from `AndBibleAddons.providedFonts`. This
 value retains the exact module/name/path spellings and the already-contained live file so consumers
 cannot reopen configs or choose a different normalization/case owner.
 */
public struct SwordAdmittedFont: Sendable, Equatable, Hashable {
    /// Exact installed module initials that own the provider metadata.
    public let moduleName: String

    /// Exact user-visible family name stored before the first provider semicolon.
    public let name: String

    /// Exact safe relative font path stored after the first provider semicolon.
    public let relativePath: String

    /// Contained, readable live font file resolved from the owner's adjusted location.
    public let fileURL: URL

    /**
     Creates one ownership-proven font provider.

     - Parameters:
       - moduleName: Exact installed module initials.
       - name: Exact provided font-family name.
       - relativePath: Safe path relative to the installed book location.
       - fileURL: Contained readable live font file.
     - Side effects: None.
     - Failure modes: None; the shared manager validates metadata and storage before construction.
     */
    init(moduleName: String, name: String, relativePath: String, fileURL: URL) {
        self.moduleName = moduleName
        self.name = name
        self.relativePath = relativePath
        self.fileURL = fileURL
    }

    /**
     Compares every string field with exact Java UTF-16 identity and the resolved file URL.

     - Parameters:
       - lhs: First admitted provider.
       - rhs: Second admitted provider.
     - Returns: True only when exact owner/name/path identities and resolved URLs match.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func == (lhs: SwordAdmittedFont, rhs: SwordAdmittedFont) -> Bool {
        SwordJavaExactStringIdentity(lhs.moduleName) == SwordJavaExactStringIdentity(rhs.moduleName)
            && SwordJavaExactStringIdentity(lhs.name) == SwordJavaExactStringIdentity(rhs.name)
            && SwordJavaExactStringIdentity(lhs.relativePath)
                == SwordJavaExactStringIdentity(rhs.relativePath)
            && lhs.fileURL == rhs.fileURL
    }

    /**
     Hashes exact Java string identities plus the already-resolved file URL.

     - Parameter hasher: Standard-library hasher receiving exact provider identity fields.
     - Side effects: Mutates only the supplied hasher.
     - Failure modes: None.
     */
    public func hash(into hasher: inout Hasher) {
        hasher.combine(SwordJavaExactStringIdentity(moduleName))
        hasher.combine(SwordJavaExactStringIdentity(name))
        hasher.combine(SwordJavaExactStringIdentity(relativePath))
        hasher.combine(fileURL)
    }
}
