// SwordInstalledAddonRemovalTarget.swift — Opaque installed add-on deletion ownership

import Foundation

/**
 Identifies the exact installed owner Android deletes for one admitted add-on row.

 Add-on initials are not a unique deletion key: JSword can retain comparator-distinct books with
 the same initials, and generated `CsvPromptBook` rows have no `.conf` file at all. Consumers keep
 this value opaque and return it to `ModuleRepository`, which revalidates the concrete config or CSV
 owner under the module-store mutation lease before removing anything.
 */
public struct SwordInstalledAddonRemovalTarget: Sendable, Hashable {
    /** Exact storage owner retained from the installed registry generation. */
    enum Storage: Sendable {
        /// Direct-root SWORD config plus the metadata that identifies its installed Book.
        case swordConfig(
            relativePath: String,
            moduleName: String,
            fullName: String,
            abbreviation: String,
            driver: String,
            dataPath: String,
            locationRelativePath: String?
        )

        /// Generated `CsvPromptBook` backed by one exact file in the root `prompts` directory.
        case standalonePromptCSV(fileName: String, moduleName: String)
    }

    /// Exact installed storage owner; package consumers cannot construct or inspect it.
    let storage: Storage

    /// Module initials used only for matching search-index cleanup and public error presentation.
    let moduleName: String

    /**
     Creates an opaque config-backed removal identity from one admitted installed Book.

     - Parameters:
       - relativePath: Canonical direct-root config path relative to the SWORD home.
       - moduleName: Exact JSword initials.
       - fullName: Exact JSword name participating in Book equality/order.
       - abbreviation: Exact JSword abbreviation participating in chooser identity/order.
       - driver: Exact `ModDrv` value that determines the concrete Book class and payload layout.
       - dataPath: Exact normalized `DataPath` value bound to the installed payload.
       - locationRelativePath: JSword-adjusted directory relative to the canonical SWORD root, or
         nil when the installed Book has no adjusted location.
     - Side effects: None.
     - Failure modes: None; the mutation boundary independently revalidates every field and path.
     */
    init(
        configRelativePath relativePath: String,
        moduleName: String,
        fullName: String,
        abbreviation: String,
        driver: String,
        dataPath: String,
        locationRelativePath: String?
    ) {
        storage = .swordConfig(
            relativePath: relativePath,
            moduleName: moduleName,
            fullName: fullName,
            abbreviation: abbreviation,
            driver: driver,
            dataPath: dataPath,
            locationRelativePath: locationRelativePath
        )
        self.moduleName = moduleName
    }

    /**
     Creates an opaque generated-prompt removal identity from its exact CSV owner.

     - Parameters:
       - fileName: Exact direct child name inside the SWORD root's `prompts` directory.
       - moduleName: Exact Android-generated `Prompts_<stem>` initials.
     - Side effects: None.
     - Failure modes: None; the mutation boundary revalidates the direct-child CSV relationship.
     */
    init(standalonePromptFileName fileName: String, moduleName: String) {
        storage = .standalonePromptCSV(fileName: fileName, moduleName: moduleName)
        self.moduleName = moduleName
    }

    /**
     Compares opaque owners with Java's exact UTF-16 string identity.

     - Parameters:
       - lhs: First captured installed owner.
       - rhs: Second captured installed owner.
     - Returns: `true` only when both targets have the same storage family and every string or
       optional string has identical raw UTF-16 code units.
     - Side effects: None.
     - Failure modes: None; different storage families and nil/value mismatches compare false.
     */
    public static func == (
        lhs: SwordInstalledAddonRemovalTarget,
        rhs: SwordInstalledAddonRemovalTarget
    ) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case let (
            .swordConfig(
                lhsPath,
                lhsName,
                lhsFullName,
                lhsAbbreviation,
                lhsDriver,
                lhsDataPath,
                lhsLocation
            ),
            .swordConfig(
                rhsPath,
                rhsName,
                rhsFullName,
                rhsAbbreviation,
                rhsDriver,
                rhsDataPath,
                rhsLocation
            )
        ):
            return Self.javaStringsAreExactlyEqual(lhsPath, rhsPath)
                && Self.javaStringsAreExactlyEqual(lhsName, rhsName)
                && Self.javaStringsAreExactlyEqual(lhsFullName, rhsFullName)
                && Self.javaStringsAreExactlyEqual(lhsAbbreviation, rhsAbbreviation)
                && Self.javaStringsAreExactlyEqual(lhsDriver, rhsDriver)
                && Self.javaStringsAreExactlyEqual(lhsDataPath, rhsDataPath)
                && Self.javaOptionalStringsAreExactlyEqual(lhsLocation, rhsLocation)
        case let (
            .standalonePromptCSV(lhsFileName, lhsName),
            .standalonePromptCSV(rhsFileName, rhsName)
        ):
            return Self.javaStringsAreExactlyEqual(lhsFileName, rhsFileName)
                && Self.javaStringsAreExactlyEqual(lhsName, rhsName)
        case (.swordConfig, .standalonePromptCSV), (.standalonePromptCSV, .swordConfig):
            return false
        }
    }

    /**
     Hashes the exact installed owner without Swift canonical-equivalence folding.

     - Parameter hasher: Standard-library hasher receiving the storage discriminator and raw UTF-16
       identity of every stored string.
     - Side effects: Mutates only `hasher`.
     - Failure modes: None.
     */
    public func hash(into hasher: inout Hasher) {
        switch storage {
        case let .swordConfig(
            relativePath,
            moduleName,
            fullName,
            abbreviation,
            driver,
            dataPath,
            locationRelativePath
        ):
            hasher.combine(0)
            hasher.combine(SwordJavaExactStringIdentity(relativePath))
            hasher.combine(SwordJavaExactStringIdentity(moduleName))
            hasher.combine(SwordJavaExactStringIdentity(fullName))
            hasher.combine(SwordJavaExactStringIdentity(abbreviation))
            hasher.combine(SwordJavaExactStringIdentity(driver))
            hasher.combine(SwordJavaExactStringIdentity(dataPath))
            hasher.combine(locationRelativePath.map(SwordJavaExactStringIdentity.init))
        case let .standalonePromptCSV(fileName, moduleName):
            hasher.combine(1)
            hasher.combine(SwordJavaExactStringIdentity(fileName))
            hasher.combine(SwordJavaExactStringIdentity(moduleName))
        }
    }

    /**
     Compares two nonoptional strings with Java's raw UTF-16 identity.

     - Parameters:
       - lhs: First stored metadata/path value.
       - rhs: Second stored metadata/path value.
     - Returns: `true` only when both raw UTF-16 code-unit sequences match.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func javaStringsAreExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaExactStringIdentity(lhs) == SwordJavaExactStringIdentity(rhs)
    }

    /**
     Compares two optional strings with Java's nil-or-raw-UTF-16 identity.

     - Parameters:
       - lhs: First optional adjusted-location path.
       - rhs: Second optional adjusted-location path.
     - Returns: `true` for two nil values or two code-unit-identical strings.
     - Side effects: None.
     - Failure modes: None; nil/value mismatches compare false.
     */
    private static func javaOptionalStringsAreExactlyEqual(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return javaStringsAreExactlyEqual(lhs, rhs)
        case (nil, nil):
            return true
        case (.some, nil), (nil, .some):
            return false
        }
    }
}
