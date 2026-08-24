// SwordInstalledRegistryModels.swift — Immutable registry/cache handoff models for SwordManager

import Foundation

/** One supported native SWORD owner with exact config, handle, and JSword ordering metadata. */
struct NativeModuleRegistration {
    /// Exact native module handle whose metadata initials match `info.name` by Java equality.
    let module: SwordModule

    /// Inclusive installed metadata, including current locked/unlocked ownership state.
    let info: ModuleInfo

    /// Parsed JSword abbreviation, falling back to exact initials when absent or Java-empty.
    let abbreviation: String

    /// Exact config `Description` used by JSword's full-name map and final TreeSet tie-break.
    let fullName: String

    /// Exact installed config owner used for verified cipher-key persistence.
    let configURL: URL
}

/** Native inventory separated from registrations whose backend ownership is provably unique. */
struct NativeModuleRegistrySnapshot {
    /// Payload-admitted native books eligible for installed-TreeSet projection.
    let installedBooks: [NativeInstalledBook]

    /// Supported native metadata rows eligible for installed-TreeSet projection.
    var installedRegistrations: [InstalledModuleRegistration] {
        installedBooks.map(\.registration)
    }

    /// Ownership-proven registrations keyed by unique exact initials.
    let exactInitials: [SwordJavaExactStringIdentity: NativeModuleRegistration]

    /// Ownership-proven registrations keyed only by unique exact full names.
    let exactFullNames: [SwordJavaExactStringIdentity: NativeModuleRegistration]

    /// Exact full-name keys withheld because multiple native books claim them.
    let ambiguousExactFullNames: Set<SwordJavaExactStringIdentity>

    /// Ownership-proven registrations in installed JSword TreeSet order for alias lookup.
    let treeSetRegistrations: [NativeModuleRegistration]
}

/** One native book after JSword payload adjustment and driver HashSet admission. */
struct NativeInstalledBook {
    /// Metadata and abbreviation captured from the admitted native owner.
    let registration: InstalledModuleRegistration

    /// Exact parsed config that produced this installed book.
    let config: SwordModuleConfig

    /// JSword-adjusted feature location, or nil when slashless `DataPath` retained no location.
    let locationURL: URL?
}

/** One installed add-on candidate before TreeSet replacement and compatibility filtering. */
struct InstalledAddonCandidate {
    /// Metadata and abbreviation participating in installed TreeSet comparison.
    let registration: InstalledModuleRegistration

    /// Parsed feature metadata supplying minimum version and prompt-pack filename.
    let config: SwordModuleConfig

    /// Filesystem-adjusted location used by feature consumers, when JSword assigned one.
    let locationURL: URL?

    /// Exact installed config or generated CSV owner used for deletion.
    let removalTarget: SwordInstalledAddonRemovalTarget
}

/** One immutable installed generation shared by public inventory and add-on consumers. */
struct InstalledRegistryProjection {
    /// Supported public books after the complete Android add sequence and TreeSet replay.
    let registrations: [SwordInstalledBookRegistration]

    /// Installed add-on owners carrying config and location before compatibility filtering.
    let addonCandidates: [InstalledAddonCandidate]
}

/** Metadata and JSword abbreviation required to merge every installed book family. */
struct InstalledModuleRegistration {
    /// Inclusive installed metadata returned through the public inventory API.
    let info: ModuleInfo

    /// Exact JSword abbreviation used after category in installed-TreeSet ordering.
    let abbreviation: String

    /// Exact user-visible name used by JSword's final raw UTF-16 tie-break.
    let fullName: String
}

/** Concrete JSword `AbstractBook` subclass participating in native driver-set equality. */
enum NativeSwordBookClassIdentity: Hashable {
    /// Verse-keyed `SwordBook` produced by text/commentary/raw-files book types.
    case swordBook

    /// List-keyed `SwordDictionary` produced by native lexical-data book types.
    case swordDictionary

    /// Calendar-keyed `SwordDailyDevotion` produced by daily-devotional lexical data.
    case swordDailyDevotion

    /// Tree-keyed `SwordGenBook` produced by native generic-book data.
    case swordGenBook
}

/** Hash identity used by `SwordBookDriver` before its arbitrary-order book array is returned. */
struct NativeSwordBookHashIdentity: Hashable {
    /// Concrete `AbstractBook` subclass created by the config's supported JSword `BookType`.
    let bookClass: NativeSwordBookClassIdentity

    /// Pinned JSword category ordinal participating in metadata equality.
    let categoryOrdinal: Int

    /// Exact Java initials participating in metadata equality.
    let initials: SwordJavaExactStringIdentity

    /// Exact Java full name participating in metadata equality.
    let fullName: SwordJavaExactStringIdentity
}

/** Hash identity for one comparator slot in JSword's installed `TreeSet`. */
struct InstalledBookSetIdentity: Hashable {
    /// Pinned JSword category ordinal, the comparator's first field.
    let categoryOrdinal: Int

    /// Java case-insensitive abbreviation identity, the comparator's second field.
    let abbreviation: SwordJavaStringIdentity

    /// Exact Java initials, the comparator's third field.
    let initials: SwordJavaExactStringIdentity

    /// Exact Java full name, the comparator's final field.
    let fullName: SwordJavaExactStringIdentity
}
