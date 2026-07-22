import Foundation

/**
 Resource ceilings applied while planning an Android module-backup archive.

 Production defaults do not impose arbitrary archive byte ceilings. File-backed restore streams
 payloads through bounded buffers and performs a destination-capacity preflight before extraction;
 callers may still inject smaller byte limits for policy tests or constrained hosts. Entry count,
 metadata, path, and expansion-ratio limits remain explicit abuse boundaries.
 */
public struct AndroidModuleBackupArchiveLimits: Sendable, Equatable {
    /// Largest complete ZIP payload accepted by the in-memory planner.
    public let maximumArchiveByteCount: UInt64

    /// Largest number of local ZIP entries, including directories and the optional manifest.
    public let maximumEntryCount: Int

    /// Largest compressed payload accepted for one file entry.
    public let maximumEntryCompressedByteCount: UInt64

    /// Largest expanded payload accepted for one file entry.
    public let maximumEntryExpandedByteCount: UInt64

    /// Largest sum of compressed payload bytes across all entries.
    public let maximumAggregateCompressedByteCount: UInt64

    /// Largest sum of expanded payload bytes across all entries.
    public let maximumAggregateExpandedByteCount: UInt64

    /// Largest rounded-up expanded-to-compressed ratio accepted for a non-empty entry.
    public let maximumExpansionRatio: UInt64

    /// Largest manifest or SWORD configuration payload materialized as metadata.
    public let maximumMetadataEntryByteCount: UInt64

    /// Largest UTF-8 byte count accepted for one raw archive path.
    public let maximumPathByteCount: UInt64

    /**
     Creates a complete resource policy for archive planning.

     Zero is a valid limit and rejects any corresponding resource use. The initializer performs no
     I/O and does not mutate global policy.

     - Parameters:
       - maximumArchiveByteCount: Maximum complete archive size.
       - maximumEntryCount: Maximum local-entry count, including directories.
       - maximumEntryCompressedByteCount: Maximum compressed size of one entry.
       - maximumEntryExpandedByteCount: Maximum expanded size of one entry.
       - maximumAggregateCompressedByteCount: Maximum sum of compressed entry sizes.
       - maximumAggregateExpandedByteCount: Maximum sum of expanded entry sizes.
       - maximumExpansionRatio: Maximum rounded-up expansion ratio for one non-empty entry.
       - maximumMetadataEntryByteCount: Maximum manifest or configuration size.
       - maximumPathByteCount: Maximum UTF-8 path size.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; planning rejects values that exceed the limits.
     */
    public init(
        maximumArchiveByteCount: UInt64 = .max,
        maximumEntryCount: Int = 10_000,
        maximumEntryCompressedByteCount: UInt64 = .max,
        maximumEntryExpandedByteCount: UInt64 = .max,
        maximumAggregateCompressedByteCount: UInt64 = .max,
        maximumAggregateExpandedByteCount: UInt64 = .max,
        maximumExpansionRatio: UInt64 = 1_000,
        maximumMetadataEntryByteCount: UInt64 = 1024 * 1024,
        maximumPathByteCount: UInt64 = 4 * 1024
    ) {
        self.maximumArchiveByteCount = maximumArchiveByteCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumEntryCompressedByteCount = maximumEntryCompressedByteCount
        self.maximumEntryExpandedByteCount = maximumEntryExpandedByteCount
        self.maximumAggregateCompressedByteCount = maximumAggregateCompressedByteCount
        self.maximumAggregateExpandedByteCount = maximumAggregateExpandedByteCount
        self.maximumExpansionRatio = maximumExpansionRatio
        self.maximumMetadataEntryByteCount = maximumMetadataEntryByteCount
        self.maximumPathByteCount = maximumPathByteCount
    }
}

/**
 Android backup type accepted by the module-backup planner.
 */
public enum AndroidModuleBackupArchiveType: String, Sendable, Equatable {
    /// Android's module archive type written by `BackupControl.createModulesZip`.
    case moduleBackup = "MODULE_BACKUP"
}

/**
 Android database-content values optionally listed by an archive manifest.

 Unknown values make the first manifest undecodable on Android and therefore send module restore
 through generic installation; `ManifestDTO` preserves that behavior by decoding this typed enum.
 */
public enum AndroidModuleBackupArchiveContainedData: String, Codable, Sendable, Equatable, Hashable {
    /// Bookmark records and labels.
    case bookmarks = "BOOKMARKS"

    /// Workspace/window records.
    case workspaces = "WORKSPACES"

    /// Reading-plan progress.
    case readingPlans = "READINGPLANS"

    /// Application settings.
    case settings = "SETTINGS"

    /// Repository definitions.
    case repositories = "REPOSITORIES"

    /// Installed SWORD and database modules.
    case modules = "MODULES"

    /// EPUB documents.
    case epubs = "EPUBS"

    /// My Documents content.
    case myDocuments = "MYDOCUMENTS"

    /// AI provider and prompt settings.
    case aiSettings = "AI_SETTINGS"
}

/**
 Validated first-entry Android backup manifest.

 Android defaults an omitted manifest version to `1`, `contains` to `nil`, and an omitted
 `andBibleVersion` to the current Android runtime version. Since iOS cannot reconstruct that runtime
 value, the planner exposes deterministic sentinel `0` for omission; explicit JSON `null` remains a
 decode failure and follows Android's generic-install fallback.
 */
public struct AndroidModuleBackupArchiveManifest: Sendable, Equatable {
    /// Typed Android backup kind; planning accepts only module backups.
    public let backupType: AndroidModuleBackupArchiveType

    /// Optional database-content categories encoded by Android.
    public let contains: Set<AndroidModuleBackupArchiveContainedData>?

    /// Validated manifest schema version.
    public let manifestVersion: Int

    /// Android application version that produced the archive, or `0` when the field was omitted.
    public let andBibleVersion: Int

    /**
     Creates a validated module-backup manifest value.

     - Parameters:
       - backupType: Typed Android backup kind.
       - contains: Optional Android database-content categories.
       - manifestVersion: Supported schema version.
       - andBibleVersion: Producing Android version, or omission sentinel `0`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; validation belongs to the planner.
     */
    public init(
        backupType: AndroidModuleBackupArchiveType,
        contains: Set<AndroidModuleBackupArchiveContainedData>? = nil,
        manifestVersion: Int,
        andBibleVersion: Int
    ) {
        self.backupType = backupType
        self.contains = contains
        self.manifestVersion = manifestVersion
        self.andBibleVersion = andBibleVersion
    }
}

/**
 How Android would interpret the archive's manifest position.

 `AndBibleBackupManifest.fromUri` reads only the literal first ZIP entry. A later manifest is not
 authoritative and therefore leaves the archive on Android's legacy content-inference path.
 */
public enum AndroidModuleBackupManifestDisposition: Sendable, Equatable {
    /// The literal first local ZIP entry was a valid module-backup manifest.
    case validatedFirstEntry(AndroidModuleBackupArchiveManifest)

    /// A manifest was non-first or unusable, so Android follows generic module installation.
    case legacyManifestNotFirst

    /// No manifest entry existed and content families were inferred from archive paths.
    case legacyWithoutManifest
}

/**
 Typed destination family for one Android module-backup entry.
 */
public enum AndroidModuleBackupContentFamily: String, Sendable, Equatable, Hashable, CaseIterable {
    /// A SWORD module descriptor under `mods.d`.
    case swordConfiguration

    /// Config-owned SWORD data or a safe extracted file with no specialized Android registrar.
    case swordPayload

    /// MyBible SQLite content under `mybible`.
    case myBible

    /// MySword SQLite content under `mysword`.
    case mySword

    /// e-Sword SQLite content under `esword`.
    case eSword

    /// Expanded EPUB module content under `epub`.
    case epub

    /// Font module content under `ttf`.
    case ttf

    /// Background-image module content under `background`.
    case background

    /// CSV prompt-pack content under `prompts`.
    case prompts
}

/**
 One validated file entry in local ZIP order.

 The relative path is the exact normalized destination spelling: separators and `.` segments are
 normalized, `..` segments are rejected, and case and Unicode scalar content are preserved. Payload
 bytes are intentionally absent so this remains a publication plan rather than an extraction model.
 */
public struct AndroidModuleBackupPlannedEntry: Sendable, Equatable {
    /// Zero-based position among all local ZIP entries, including skipped directories and manifest.
    public let archivePosition: Int

    /// Exact member name recorded by the ZIP before destination normalization.
    public let sourcePath: String

    /// Exact normalized path relative to Android's modules directory.
    public let relativePath: String

    /// Typed destination family selected from path and SWORD ownership metadata.
    public let family: AndroidModuleBackupContentFamily

    /// Compressed payload bytes declared by the ZIP central directory.
    public let compressedByteCount: UInt64

    /// Expanded payload bytes declared by ZIP metadata and checked while transactional staging reads it.
    public let expandedByteCount: UInt64

    /// ZIP CRC32 declared for the uncompressed payload.
    public let crc32: UInt32

    /// Configuration paths whose `DataPath` owns this payload, in archive order.
    public let owningConfigurationPaths: [String]

    /**
     Creates one immutable planned file entry.

     - Parameters:
       - archivePosition: Position in local ZIP order.
       - sourcePath: Exact ZIP member name used to bind streamed extraction to this plan row.
       - relativePath: Validated modules-directory-relative destination.
       - family: Typed content family.
       - compressedByteCount: Declared compressed size.
       - expandedByteCount: Declared expanded size.
       - crc32: Declared ZIP checksum, verified for metadata now and other payloads during staging.
       - owningConfigurationPaths: Configurations that own this payload, if any.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; the planner establishes all invariants first.
     */
    public init(
        archivePosition: Int,
        sourcePath: String,
        relativePath: String,
        family: AndroidModuleBackupContentFamily,
        compressedByteCount: UInt64,
        expandedByteCount: UInt64,
        crc32: UInt32,
        owningConfigurationPaths: [String]
    ) {
        self.archivePosition = archivePosition
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.family = family
        self.compressedByteCount = compressedByteCount
        self.expandedByteCount = expandedByteCount
        self.crc32 = crc32
        self.owningConfigurationPaths = owningConfigurationPaths
    }
}

/**
 Ordered entries belonging to one typed Android module family.
 */
public struct AndroidModuleBackupFamilyPlan: Sendable, Equatable {
    /// Family represented by every entry in `entries`.
    public let family: AndroidModuleBackupContentFamily

    /// Family entries in their original local ZIP order.
    public let entries: [AndroidModuleBackupPlannedEntry]

    /**
     Creates one family grouping without changing archive order.

     - Parameters:
       - family: Typed content family.
       - entries: Entries already classified into that family.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; callers are responsible for family consistency.
     */
    public init(
        family: AndroidModuleBackupContentFamily,
        entries: [AndroidModuleBackupPlannedEntry]
    ) {
        self.family = family
        self.entries = entries
    }
}

/**
 Complete read-only publication plan for one Android module-backup archive.

 The model preserves local archive order and exact normalized destinations. It contains no file
 handles or mutable state, allowing later transactional integration to revalidate and publish the
 represented entries without coupling archive recognition to UI or format readers.
 */
public struct AndroidModuleBackupArchivePlan: Sendable, Equatable {
    /// Android first-entry manifest result or legacy inference mode.
    public let manifestDisposition: AndroidModuleBackupManifestDisposition

    /// Every installable file entry in local ZIP order, excluding the manifest.
    public let entries: [AndroidModuleBackupPlannedEntry]

    /// Typed family groupings ordered by each family's first archive appearance.
    public let families: [AndroidModuleBackupFamilyPlan]

    /// SWORD module initials in configuration-entry order.
    public let swordModuleNames: [String]

    /// SWORD full display names in the same configuration-entry order.
    public let swordModuleDisplayNames: [String]

    /// Metadata-invalid SWORD configuration paths excluded while retaining valid sibling families.
    public let rejectedSwordConfigurationPaths: [String]

    /// Whether an exact first manifest was malformed/non-module and Android chose generic install.
    public let firstManifestFellBackToGenericInstall: Bool

    /// Planned relative destinations colliding with caller-supplied existing paths.
    public let conflictPaths: [String]

    /// Sum of compressed sizes for all ZIP entries, including a manifest when present.
    public let aggregateCompressedByteCount: UInt64

    /// Sum of expanded sizes for all ZIP entries, including a manifest when present.
    public let aggregateExpandedByteCount: UInt64

    /**
     Creates an immutable archive plan after structural and metadata-payload validation passes.

     - Parameters:
       - manifestDisposition: Android-compatible manifest interpretation.
       - entries: Installable entries in local archive order.
       - families: Entries grouped by typed family.
       - swordModuleNames: Module initials parsed from SWORD configurations in archive order.
       - swordModuleDisplayNames: Full names parsed from the same configurations, or initials when
         `Description` is absent.
       - rejectedSwordConfigurationPaths: Configurations whose bounded payload was valid ZIP data but
         could not produce safe supported SWORD ownership metadata.
       - firstManifestFellBackToGenericInstall: `true` when Android's exact first-manifest parser
         deliberately abandoned typed backup routing and continued through generic installation.
       - conflictPaths: Planned destinations matching existing paths.
       - aggregateCompressedByteCount: Archive-wide compressed payload sum.
       - aggregateExpandedByteCount: Archive-wide expanded payload sum.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; only the planner should construct validated plans.
     */
    public init(
        manifestDisposition: AndroidModuleBackupManifestDisposition,
        entries: [AndroidModuleBackupPlannedEntry],
        families: [AndroidModuleBackupFamilyPlan],
        swordModuleNames: [String],
        swordModuleDisplayNames: [String],
        rejectedSwordConfigurationPaths: [String] = [],
        firstManifestFellBackToGenericInstall: Bool = false,
        conflictPaths: [String],
        aggregateCompressedByteCount: UInt64,
        aggregateExpandedByteCount: UInt64
    ) {
        self.manifestDisposition = manifestDisposition
        self.entries = entries
        self.families = families
        self.swordModuleNames = swordModuleNames
        self.swordModuleDisplayNames = swordModuleDisplayNames
        self.rejectedSwordConfigurationPaths = rejectedSwordConfigurationPaths
        self.firstManifestFellBackToGenericInstall = firstManifestFellBackToGenericInstall
        self.conflictPaths = conflictPaths
        self.aggregateCompressedByteCount = aggregateCompressedByteCount
        self.aggregateExpandedByteCount = aggregateExpandedByteCount
    }
}

/**
 Bounded resource whose declared archive use exceeded planner policy.
 */
public enum AndroidModuleBackupArchiveResource: String, Sendable, Equatable {
    /// Complete ZIP byte count.
    case archiveBytes

    /// Number of local entries, including directories.
    case entryCount

    /// Compressed bytes declared for one entry.
    case entryCompressedBytes

    /// Expanded bytes declared for one entry.
    case entryExpandedBytes

    /// Sum of compressed bytes across entries.
    case aggregateCompressedBytes

    /// Sum of expanded bytes across entries.
    case aggregateExpandedBytes

    /// Rounded-up expanded-to-compressed ratio for one entry.
    case expansionRatio

    /// Expanded bytes used by a manifest or SWORD configuration.
    case metadataEntryBytes

    /// UTF-8 bytes used by one raw archive path.
    case pathBytes
}

/**
 Deterministic failures raised before an Android module archive can become a publication plan.
 */
public enum AndroidModuleBackupArchivePlannerError: LocalizedError, Sendable, Equatable {
    /// ZIP structure, compression, truncation, or payload integrity was invalid.
    case invalidArchive(String)

    /// An entry path was absolute, NUL-containing, empty after normalization, or escaped the root.
    case unsafeEntryPath(String)

    /// ZIP external attributes represented a symbolic link or another non-file special node.
    case symbolicLink(String)

    /// Two archive entries normalized to the same exact destination spelling.
    case duplicateEntry(String)

    /// Two distinct spellings or incompatible parent/child entries target the same destination tree.
    case destinationCollision(first: String, second: String)

    /// The literal first manifest entry was not valid Android manifest JSON.
    case malformedManifest

    /// The first manifest declared a backup type other than `MODULE_BACKUP`.
    case unsupportedBackupType(String)

    /// The first manifest declared a schema version the planner does not implement.
    case unsupportedManifestVersion(Int)

    /// Declared archive use exceeded one configured resource ceiling.
    case resourceLimitExceeded(
        resource: AndroidModuleBackupArchiveResource,
        limit: UInt64,
        actual: UInt64
    )

    /// A `mods.d` entry could not provide a valid section, `DataPath`, or relative ownership root.
    case malformedSwordConfiguration(String)

    /// A SWORD `DataPath` was absolute, traversing, encoded, or targeted reserved metadata.
    case unsafeSwordConfigurationDataPath(String)

    /// A configuration filename did not identify the same module as its section header.
    case swordConfigurationNameMismatch(path: String, moduleName: String)

    /// Two SWORD configurations declared the same module initials.
    case duplicateSwordModuleInitials(String)

    /// Two SWORD configurations could own at least one of the same payload paths.
    case overlappingSwordOwnership(first: String, second: String)

    /// One payload matched more than one SWORD configuration ownership rule.
    case ambiguousSwordPayload(String)

    /// A file or directory belonged to no Android family and no SWORD `DataPath` ownership root.
    case unsupportedEntry(String)

    /// A SWORD configuration had no archive payload under its owned data root.
    case missingSwordPayload(String)

    /// The archive contained no installable Android module content.
    case noModuleContent

    /// Human-readable failure detail suitable for logs and preflight error presentation.
    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            return "Invalid Android module archive: \(message)"
        case .unsafeEntryPath(let path):
            return "Unsafe Android module archive path: \(path)"
        case .symbolicLink(let path):
            return "Android module archive contains a symbolic link: \(path)"
        case .duplicateEntry(let path):
            return "Android module archive contains duplicate destination: \(path)"
        case .destinationCollision(let first, let second):
            return "Android module archive destinations collide: \(first) and \(second)"
        case .malformedManifest:
            return "Android module archive manifest is malformed."
        case .unsupportedBackupType(let type):
            return "Android backup type \(type) is not a module backup."
        case .unsupportedManifestVersion(let version):
            return "Android module archive manifest version \(version) is unsupported."
        case .resourceLimitExceeded(let resource, let limit, let actual):
            return "Android module archive exceeds \(resource.rawValue) limit \(limit) with \(actual)."
        case .malformedSwordConfiguration(let path):
            return "Android module archive contains malformed SWORD configuration \(path)."
        case .unsafeSwordConfigurationDataPath(let path):
            return "Android module archive contains unsafe SWORD DataPath in \(path)."
        case .swordConfigurationNameMismatch(let path, let moduleName):
            return "SWORD configuration \(path) does not match module initials \(moduleName)."
        case .duplicateSwordModuleInitials(let moduleName):
            return "Android module archive contains duplicate SWORD initials \(moduleName)."
        case .overlappingSwordOwnership(let first, let second):
            return "SWORD configurations \(first) and \(second) own overlapping payloads."
        case .ambiguousSwordPayload(let path):
            return "SWORD payload \(path) has ambiguous configuration ownership."
        case .unsupportedEntry(let path):
            return "Android module archive contains unsupported entry \(path)."
        case .missingSwordPayload(let path):
            return "SWORD configuration \(path) has no owned archive payload."
        case .noModuleContent:
            return "Android module archive contains no installable module content."
        }
    }
}
