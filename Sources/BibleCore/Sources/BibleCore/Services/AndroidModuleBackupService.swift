// AndroidModuleBackupService.swift — Android .abmd.zip module backup import/export support

import Foundation
import SwordKit

/**
 Android module backup manifest payload read from `AndBibleBackupManifest.json`.

 Android writes this manifest as the first entry in `.abmd.zip` archives. iOS requires the
 `MODULE_BACKUP` type before installing any files so database backups and module backups cannot be
 accidentally routed through the wrong restore path.
 */
public struct AndroidModuleBackupManifest: Sendable, Equatable {
    /// Android backup type string, expected to be `MODULE_BACKUP`.
    public let backupType: String

    /// Manifest schema version. Android currently writes version `1`.
    public let manifestVersion: Int

    /// Android application version that created the backup, when present.
    public let andBibleVersion: Int?

    /**
     Creates one decoded Android module backup manifest.

     - Parameters:
       - backupType: Android backup type string.
       - manifestVersion: Manifest schema version.
       - andBibleVersion: Android application version, when present.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(backupType: String, manifestVersion: Int, andBibleVersion: Int?) {
        self.backupType = backupType
        self.manifestVersion = manifestVersion
        self.andBibleVersion = andBibleVersion
    }
}

/**
 Non-destructive summary of one Android module backup archive.

 The import UI uses this to present every Android module family and bind exact overwrite conflicts
 to the archive bytes presented for confirmation.
 */
public struct AndroidModuleBackupInspection: Sendable, Equatable {
    /// Decoded Android backup manifest.
    public let manifest: AndroidModuleBackupManifest

    /// Android-compatible initials derived across every planned module family.
    public let supportedModuleNames: [String]

    /// Number of validated module-family file entries that would be written during restore.
    public let supportedEntryCount: Int

    /// Sum of uncompressed bytes across validated entries that would be staged.
    public let estimatedExpandedBytes: Int64

    /// Lowercase SHA-256 of the exact backup archive inspected before confirmation.
    public let archiveSHA256: String

    /// Existing exact archive destinations that confirmed Android-style overlay will replace.
    public let existingEntryPaths: [String]

    /// Whether the archive contains at least one restorable module.
    public var hasSupportedModules: Bool { !supportedModuleNames.isEmpty }

    /// Exact archive-bound authorization retained only after the user confirms these conflicts.
    public var overwriteAuthorization: LocalSwordZipOverwriteAuthorization {
        LocalSwordZipOverwriteAuthorization(
            archiveSHA256: archiveSHA256,
            conflictingPaths: existingEntryPaths
        )
    }

    /**
     Creates one archive inspection summary.

     - Parameters:
       - manifest: Decoded Android backup manifest.
       - supportedModuleNames: Restorable Android-compatible module initials.
       - supportedEntryCount: Number of supported module-family file entries.
       - existingEntryPaths: Supported paths that already exist in the local module directory.
       - estimatedExpandedBytes: Sum of uncompressed bytes across supported entries. Synthetic
         callers may omit it when expanded-size metadata is unavailable.
       - archiveSHA256: Lowercase SHA-256 of the inspected archive bytes.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        manifest: AndroidModuleBackupManifest,
        supportedModuleNames: [String],
        supportedEntryCount: Int,
        existingEntryPaths: [String],
        estimatedExpandedBytes: Int64 = 0,
        archiveSHA256: String
    ) {
        self.manifest = manifest
        self.supportedModuleNames = supportedModuleNames
        self.supportedEntryCount = supportedEntryCount
        self.estimatedExpandedBytes = estimatedExpandedBytes
        self.existingEntryPaths = existingEntryPaths
        self.archiveSHA256 = archiveSHA256
    }
}

/** One supported-family payload omitted after isolated staged validation failed. */
public struct AndroidModuleBackupRestoreDiagnostic: Sendable, Equatable {
    /// Android family whose candidate could not be registered safely.
    public let family: AndroidModuleBackupContentFamily

    /// Exact archive-relative candidate file or EPUB root.
    public let relativePath: String

    /// User-visible validation failure retained without exposing partial live writes.
    public let message: String

    /** Creates one immutable skipped-candidate diagnostic. */
    public init(
        family: AndroidModuleBackupContentFamily,
        relativePath: String,
        message: String
    ) {
        self.family = family
        self.relativePath = relativePath
        self.message = message
    }
}

/** Summary returned after installing content from an Android module backup. */
public struct AndroidModuleBackupRestoreReport: Sendable, Equatable {
    /// Installed Android-compatible module initials across every represented family.
    public let installedModuleNames: [String]

    /// Count of validated file entries written into the local module directory.
    public let installedEntryCount: Int

    /// Supported-family candidates skipped after isolated staged validation failed.
    public let diagnostics: [AndroidModuleBackupRestoreDiagnostic]

    /**
     Creates one restore report.

     - Parameters:
       - installedModuleNames: Installed Android-compatible module initials.
       - installedEntryCount: Number of supported file entries written.
       - diagnostics: Malformed supported-family candidates omitted from the atomic publication.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        installedModuleNames: [String],
        installedEntryCount: Int,
        diagnostics: [AndroidModuleBackupRestoreDiagnostic] = []
    ) {
        self.installedModuleNames = installedModuleNames
        self.installedEntryCount = installedEntryCount
        self.diagnostics = diagnostics
    }
}

/** Android raw-file family accepted by the shared external document importer. */
public enum AndroidModuleBackupExternalFileFamily: Sendable, Equatable {
    /// MyBible `.SQLite3` document.
    case myBible

    /// MySword `.mybible` document.
    case mySword

    /// e-Sword `.bblx` or `.bbli` Bible.
    case eSword

    /// Android background image (`png`, `jpg`, `jpeg`, or `webp`).
    case background

    /// Root-level Android CSV prompt pack.
    case prompts
}

/**
 Android-compatible module backup archive produced from locally installed module families.
 */
public struct AndroidModuleBackupExport: Sendable, Equatable {
    /// Android-compatible export filename.
    public let fileName: String

    /// Raw `.abmd.zip` archive bytes.
    public let data: Data

    /// Exported Android-compatible module initials across all represented families.
    public let moduleNames: [String]

    /// Number of file entries written into the ZIP, including the manifest.
    public let entryCount: Int

    /**
     Creates one module backup export result.

     - Parameters:
       - fileName: Android-compatible backup filename.
       - data: Raw ZIP archive bytes.
       - moduleNames: Exported Android-compatible module initials.
       - entryCount: Number of ZIP file entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(fileName: String, data: Data, moduleNames: [String], entryCount: Int) {
        self.fileName = fileName
        self.data = data
        self.moduleNames = moduleNames
        self.entryCount = entryCount
    }
}

/**
 File-backed Android module backup export used by production Files and Share workflows.

 Payload files are streamed into the ZIP and remain file-backed through destination presentation,
 avoiding memory proportional to the total size of installed modules. The caller owns cleanup of
 `fileURL` after the exporter or share sheet finishes.
 */
public struct AndroidModuleBackupFileExport: Sendable, Equatable {
    /// Android-compatible filename presented to destination UI.
    public let fileName: String

    /// Complete temporary `.abmd.zip` file owned by the caller.
    public let fileURL: URL

    /// Exported Android-compatible module initials across all represented families.
    public let moduleNames: [String]

    /// Number of ZIP entries, including the manifest.
    public let entryCount: Int

    /**
     Creates one file-backed module export summary.

     - Parameters:
       - fileName: Android-compatible destination filename.
       - fileURL: Complete temporary archive URL.
       - moduleNames: Exported module initials.
       - entryCount: Number of ZIP entries, including the manifest.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(fileName: String, fileURL: URL, moduleNames: [String], entryCount: Int) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.moduleNames = moduleNames
        self.entryCount = entryCount
    }
}

/**
 Errors raised while inspecting, restoring, or exporting Android module backups.
 */
public enum AndroidModuleBackupError: LocalizedError, Equatable {
    /// The archive could not be parsed as ZIP.
    case invalidArchive(String)

    /// The required Android manifest file was missing.
    case missingManifest

    /// The Android manifest could not be decoded.
    case invalidManifest

    /// The manifest described a backup type other than `MODULE_BACKUP`.
    case unsupportedBackupType(String)

    /// The manifest version is newer than this iOS build understands.
    case unsupportedManifestVersion(Int)

    /// The archive contains only Android module formats that this iOS build cannot restore.
    case noSupportedModules([String])

    /// The archive contains Android module formats this iOS build cannot restore atomically.
    case unsupportedModuleFormats([String])

    /// The archive's supported module-family entries are incomplete or inconsistent.
    case invalidModuleLayout(String)

    /// The archive contains a duplicate file entry.
    case duplicateEntry(String)

    /// Restore was asked not to overwrite existing files and matching module paths already exist.
    case moduleFilesAlreadyExist([String])

    /// No installed Android-compatible module families were available for export.
    case noExportableModules

    /// An installed module identity references payload files that are missing locally.
    case missingExportData(moduleName: String, dataPath: String)

    /// User-visible error description.
    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            return "Invalid Android module backup archive: \(message)"
        case .missingManifest:
            return "The Android module backup manifest is missing."
        case .invalidManifest:
            return "The Android module backup manifest could not be read."
        case .unsupportedBackupType(let type):
            return "This archive is \(type), not an Android module backup."
        case .unsupportedManifestVersion(let version):
            return "This Android module backup manifest version (\(version)) is newer than iOS supports."
        case .noSupportedModules(let paths):
            if paths.isEmpty {
                return "No supported modules were found in this Android module backup."
            }
            return "This Android module backup only contains formats iOS cannot restore yet: \(paths.prefix(5).joined(separator: ", "))"
        case .unsupportedModuleFormats(let paths):
            return "This Android module backup contains formats iOS cannot restore yet: \(paths.prefix(5).joined(separator: ", ")). No modules were installed."
        case .invalidModuleLayout(let message):
            return "Invalid Android module backup layout: \(message)"
        case .duplicateEntry(let name):
            return "Android module backup contains duplicate entry \(name)."
        case .moduleFilesAlreadyExist(let files):
            return "Module files already exist: \(files.prefix(5).joined(separator: ", "))"
        case .noExportableModules:
            return "No installed modules are available for Android-compatible export."
        case .missingExportData(let moduleName, let dataPath):
            return "Cannot export \(moduleName) because its data files are missing at \(dataPath)."
        }
    }
}

/**
 Loads and exports Android `.abmd.zip` archives across every Android module family.

 Android module backups contain raw files relative to Android's modules directory. The manifest is
 authoritative only in the literal first ZIP position; older manifest-less archives use Android's
 path inference. Every accepted family is staged and validated before a single exact overlay
 transaction publishes content first and discovery/configuration files last.
 */
public final class AndroidModuleBackupService {
    /// Android module backup suffix used for file recognition.
    public static let moduleBackupSuffix = ".abmd.zip"

    /// Android's default module backup filename.
    public static let moduleBackupFileName = "AndBibleModulesBackup.abmd.zip"

    private let fileManager: FileManager
    private let moduleDirectory: URL
    private let temporaryDirectory: URL
    private let epubLibraryRootURL: URL?
    private let storagePreflight: ModuleStoragePreflight
    private let mutationPublisher: ModuleStoreTransactionPublisher
    private let archivePlanner: AndroidModuleBackupArchivePlanner
    private let exporter: AndroidModuleBackupArchiveExporter

    /**
     Creates an Android module backup service.

     - Parameters:
       - fileManager: File manager used for module file reads/writes and temporary staging.
       - moduleDirectory: Local SWORD module root. Defaults to `SwordManager.defaultModulePath()`.
       - temporaryDirectory: Scratch directory for staged restores and rollback backups.
       - epubLibraryRootURL: Optional explicit EPUB library used by isolated hosts and tests. The
         app default remains the Documents EPUB library when omitted.
       - storagePreflight: Shared Android-compatible capacity policy applied before staging.
       - producerVersion: Optional integer producer build; defaults to the current app bundle build.
     - Side effects: none. Live module directories are created only inside a mutation transaction.
     - Failure modes: none.
     */
    public init(
        fileManager: FileManager = .default,
        moduleDirectory: URL? = nil,
        temporaryDirectory: URL? = nil,
        epubLibraryRootURL: URL? = nil,
        storagePreflight: ModuleStoragePreflight = ModuleStoragePreflight(),
        producerVersion: Int? = nil
    ) {
        let resolvedModuleDirectory = moduleDirectory
            ?? URL(fileURLWithPath: SwordManager.defaultModulePath(), isDirectory: true)
        self.fileManager = fileManager
        self.moduleDirectory = resolvedModuleDirectory
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.epubLibraryRootURL = epubLibraryRootURL
        self.storagePreflight = storagePreflight
        self.mutationPublisher = ModuleStoreTransactionPublisher(
            moduleRootURL: resolvedModuleDirectory,
            fileManager: fileManager
        )
        self.archivePlanner = AndroidModuleBackupArchivePlanner()
        self.exporter = AndroidModuleBackupArchiveExporter(
            fileManager: fileManager,
            moduleDirectory: resolvedModuleDirectory,
            temporaryDirectory: temporaryDirectory ?? fileManager.temporaryDirectory,
            epubLibraryRootURL: epubLibraryRootURL,
            producerVersion: producerVersion ?? AndroidBackupManifestCodec.producerVersion()
        )
    }

    /**
     Determines whether a filename uses Android's module-backup suffix.

     - Parameter fileName: Display or URL filename to check.
     - Returns: `true` only for names ending in `.abmd.zip`, case-insensitively.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func isAndroidModuleBackupFileName(_ fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(moduleBackupSuffix)
    }

    /**
     Applies Android's external `InstallZip` module-recognition gate without publishing content.

     A candidate is recognized when it contains either a usable SWORD configuration plus owned
     payload or one of Android's externally recognized raw module roots: MyBible, MySword, e-Sword,
     or EPUB. Font, background, prompt, arbitrary, and unowned payload archives are not module
     backups merely because their filename ends in `.abmd.zip`.

     - Parameter archiveURL: Local ZIP candidate selected through an external document surface.
     - Returns: `true` only for an Android-recognized module archive shape.
     - Side effects: Reads bounded ZIP metadata, manifest bytes, and SWORD config bytes only; creates
       no scratch files and does not initialize libsword globals.
     - Failure modes: Malformed, unsafe, unsupported, and unreadable candidates return `false` so the
       generic archive path can surface its own visible validation failure.
     */
    public static func recognizesExternalModuleArchive(at archiveURL: URL) -> Bool {
        guard let plan = try? AndroidModuleBackupArchivePlanner().planArchive(at: archiveURL) else {
            return false
        }
        guard !plan.firstManifestFellBackToGenericInstall else { return false }
        let families = Set(plan.entries.map(\.family))
        let hasUsableSwordShape = families.contains(.swordConfiguration)
            && plan.entries.contains {
                $0.family == .swordPayload && !$0.owningConfigurationPaths.isEmpty
            }
        let recognizedRawFamilies: Set<AndroidModuleBackupContentFamily> = [
            .myBible, .mySword, .eSword, .epub,
        ]
        return hasUsableSwordShape || !families.isDisjoint(with: recognizedRawFamilies)
    }

    /**
     Reads an Android module backup without mutating local module files.

     - Parameter data: Raw `.abmd.zip` archive bytes.
     - Returns: Summary of supported modules and existing destination conflicts.
     - Side effects: Reads ZIP data and local file-existence state; no files are written.
     - Throws: `AndroidModuleBackupError` for malformed archives, wrong backup types, unsupported
       manifest versions, duplicate entries, or incomplete module-family layouts.
     */
    public func inspectArchive(from data: Data) throws -> AndroidModuleBackupInspection {
        try Task.checkCancellation()
        let plan = try planArchive(from: data)
        let registration = try registrationPreview(for: plan)
        let existingPaths = try existingEntryPaths(
            for: plan.entries.map(\.relativePath) + registration.generatedConfigurationPaths
        )
        return AndroidModuleBackupInspection(
            manifest: inspectionManifest(for: plan),
            supportedModuleNames: registration.archiveContent.map(\.initials),
            supportedEntryCount: plan.entries.count,
            existingEntryPaths: existingPaths,
            estimatedExpandedBytes: try estimatedExpandedBytes(for: plan.entries.lazy.map(\.expandedByteCount)),
            archiveSHA256: ArchiveFingerprint.sha256Hex(of: data)
        )
    }

    /**
     Reads an Android module backup from a file URL without mutating local module files.

     - Parameter archiveURL: File URL for a `.abmd.zip` archive.
     - Returns: Summary of supported modules and existing destination conflicts.
     - Side effects: Reads ZIP metadata and small manifest/config entries; no module files are
       written.
     - Throws: `AndroidModuleBackupError` for malformed archives, wrong backup types, unsupported
       manifest versions, duplicate entries, or incomplete module-family layouts.
     */
    public func inspectArchive(fromArchiveAt archiveURL: URL) throws -> AndroidModuleBackupInspection {
        try Task.checkCancellation()
        let initialDigest = try archiveDigest(at: archiveURL)
        let plan = try planArchive(at: archiveURL)
        let registration = try registrationPreview(for: plan)
        let finalDigest = try archiveDigest(at: archiveURL)
        guard initialDigest == finalDigest else {
            throw AndroidModuleBackupError.invalidArchive(
                "The selected archive changed during inspection. Inspect it again before restoring."
            )
        }
        let existingPaths = try existingEntryPaths(
            for: plan.entries.map(\.relativePath) + registration.generatedConfigurationPaths
        )
        return AndroidModuleBackupInspection(
            manifest: inspectionManifest(for: plan),
            supportedModuleNames: registration.archiveContent.map(\.initials),
            supportedEntryCount: plan.entries.count,
            existingEntryPaths: existingPaths,
            estimatedExpandedBytes: try estimatedExpandedBytes(for: plan.entries.lazy.map(\.expandedByteCount)),
            archiveSHA256: initialDigest
        )
    }

    /**
     Installs every supported family from an Android module backup.

     - Parameters:
       - data: Raw `.abmd.zip` archive bytes.
       - overwritePolicy: Strict rejection or archive-bound authorization for exact conflicts shown
         during read-only inspection.
     - Returns: Installed module names and the number of published archive entries.
     - Side effects:
       - stages validated SWORD, document, EPUB, font, background, and prompt files
       - stages files first, then uses rollback backups for overwritten files during publish
       - publishes one exact overlay and validates every family before committing the journal
     - Throws: `AndroidModuleBackupError` for invalid archives, unsupported-only content, or
       existing files when overwrite is disabled; `ModuleRepositoryError.insufficientStorage`
       before staging when reported capacity is too low; rethrows file-system failures during
       staging or publish after attempting rollback.
     */
    public func restoreArchive(
        from data: Data,
        overwritePolicy: LocalSwordZipOverwritePolicy = .reject
    ) throws -> AndroidModuleBackupRestoreReport {
        try Task.checkCancellation()
        let plan = try planArchive(from: data)
        let registration = try registrationPreview(for: plan)
        let archiveSHA256 = ArchiveFingerprint.sha256Hex(of: data)
        let entries = try inMemoryEntriesBySourcePath(data)
        return try restorePlannedArchive(
            plan: plan,
            registrationPreview: registration,
            archiveSHA256: archiveSHA256,
            overwritePolicy: overwritePolicy,
            extract: { plannedEntry, destinationURL in
                guard let entry = entries[plannedEntry.sourcePath],
                      UInt64(entry.data.count) == plannedEntry.expandedByteCount,
                      ArchiveCRC32.checksum(of: entry.data) == plannedEntry.crc32 else {
                    throw AndroidModuleBackupError.invalidArchive(
                        "Validated ZIP member changed before staging: \(plannedEntry.sourcePath)"
                    )
                }
                try Task.checkCancellation()
                try self.fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try entry.data.write(to: destinationURL, options: .atomic)
            },
            verifyArchiveIdentity: {}
        )
    }

    /**
     Installs every supported family from a file-backed Android module backup.

     - Parameters:
       - archiveURL: File URL for a `.abmd.zip` archive.
       - overwritePolicy: Strict rejection or archive-bound authorization for exact conflicts shown
         during read-only inspection.
     - Returns: Installed module names and the number of published archive entries.
     - Side effects:
       - streams every validated module-family file into staging
       - publishes staged files as one exact overlay with rollback backups
       - publishes native EPUB generations before the surrounding module journal commits
     - Throws: `AndroidModuleBackupError` for invalid archives, unsupported-only content, or
       existing files when overwrite is disabled; `ModuleRepositoryError.insufficientStorage`
       before staging when reported capacity is too low; rethrows file-system failures during
       staging or publish after attempting rollback.
     */
    public func restoreArchive(
        fromArchiveAt archiveURL: URL,
        overwritePolicy: LocalSwordZipOverwritePolicy = .reject
    ) throws -> AndroidModuleBackupRestoreReport {
        try Task.checkCancellation()
        let archiveSHA256 = try archiveDigest(at: archiveURL)
        let plan = try planArchive(at: archiveURL)
        let registration = try registrationPreview(for: plan)
        let entries = try fileEntriesBySourcePath(at: archiveURL)
        return try restorePlannedArchive(
            plan: plan,
            registrationPreview: registration,
            archiveSHA256: archiveSHA256,
            overwritePolicy: overwritePolicy,
            extract: { plannedEntry, destinationURL in
                guard let entry = entries[plannedEntry.sourcePath],
                      entry.uncompressedSize == plannedEntry.expandedByteCount,
                      entry.compressedSize == plannedEntry.compressedByteCount,
                      entry.checksum == plannedEntry.crc32 else {
                    throw AndroidModuleBackupError.invalidArchive(
                        "Validated ZIP member changed before staging: \(plannedEntry.sourcePath)"
                    )
                }
                do {
                    try ZipArchiveReader.extract(
                        entry,
                        fromArchiveAt: archiveURL,
                        to: destinationURL,
                        fileManager: self.fileManager
                    )
                } catch let error as ZipArchiveReaderError {
                    throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
                }
            },
            verifyArchiveIdentity: {
                guard try self.archiveDigest(at: archiveURL) == archiveSHA256 else {
                    throw AndroidModuleBackupError.invalidArchive(
                        "The selected archive changed during restore. No module files were published."
                    )
                }
            }
        )
    }

    /**
     Installs one externally selected Android raw-family file through the archive transaction.

     The source is streamed into a deterministic one-entry legacy module ZIP so the same family
     readers, generated-registration validation, overwrite authorization, containment checks, and
     rollback transaction used by backup restore remain authoritative.

     - Parameters:
       - sourceURL: Readable regular source file selected by the document importer.
       - displayFileName: Provider-visible basename retained below Android's family root.
       - family: Android raw-file registrar selected after MIME/name/content routing.
       - overwritePolicy: Exact archive-bound replacement authorization or fail-safe rejection.
     - Returns: The normal backup restore report for the installed raw-family module.
     - Side effects: Creates and removes one temporary ZIP, then transactionally publishes the raw
       file and generated registration on success.
     - Throws: Invalid filename/extension, source I/O, ZIP writing, family metadata validation,
       conflict, storage, or transactional publication errors.
     */
    public func restoreExternalFile(
        from sourceURL: URL,
        displayFileName: String,
        family: AndroidModuleBackupExternalFileFamily,
        overwritePolicy: LocalSwordZipOverwritePolicy = .reject
    ) throws -> AndroidModuleBackupRestoreReport {
        let fileName = (displayFileName as NSString).lastPathComponent
        guard fileName == displayFileName,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("\\"),
              !fileName.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "External Android module file has an unsafe display name."
            )
        }
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let familyRoot: String
        switch family {
        case .myBible where fileExtension == "sqlite3":
            familyRoot = "mybible"
        case .mySword where fileName.lowercased().hasSuffix(".mybible"):
            familyRoot = "mysword"
        case .eSword where ["bblx", "bbli"].contains(fileExtension):
            familyRoot = "esword"
        case .background where ["jpg", "jpeg", "png", "webp"].contains(fileExtension):
            familyRoot = "background"
        case .prompts where fileExtension == "csv":
            familyRoot = "prompts"
        default:
            throw AndroidModuleBackupError.invalidModuleLayout(
                "External file extension does not match its Android module family."
            )
        }

        let archiveURL = temporaryDirectory.appendingPathComponent(
            "android-external-module-\(UUID().uuidString).zip"
        )
        defer { try? fileManager.removeItem(at: archiveURL) }
        try ZipArchiveWriter.writeStoredArchive(
            entries: [ZipArchiveWriterFileEntry(
                name: "\(familyRoot)/\(fileName)",
                fileURL: sourceURL
            )],
            to: archiveURL,
            fileManager: fileManager
        )
        return try restoreArchive(fromArchiveAt: archiveURL, overwritePolicy: overwritePolicy)
    }

    /**
     Exports installed Android-compatible module families as in-memory `.abmd.zip` bytes.

     - Parameter moduleNames: Optional Android-compatible initials across SWORD, SQLite document,
       EPUB, font, background, and prompt families. `nil` exports every discovered module.
     - Returns: Android-compatible module backup bytes and exported module initials.
     - Side effects: Streams a temporary file-backed archive, reads it into memory for compatibility,
       then removes the temporary file. Production destination flows should use `exportArchiveFile`.
     - Throws: `AndroidModuleBackupError` for missing/unsafe/colliding installed content and
       `ZipArchiveWriterError` when the archive cannot be represented or persisted as ZIP64.
     */
    public func exportArchive(moduleNames: Set<String>? = nil) throws -> AndroidModuleBackupExport {
        try exporter.exportArchive(moduleNames: moduleNames)
    }

    /**
     Streams every selected Android module family into one `.abmd.zip` backup.

     SWORD entries retain driver-owned payload boundaries. Android-native custom families are
     discovered from their canonical roots, while iOS EPUB generations contribute expanded package
     trees only when no authoritative raw Android tree owns the same initials.

     - Parameter moduleNames: Optional Android-compatible initials for every family; `nil` selects
       all discovered modules.
     - Returns: Complete temporary archive plus exported module summary. The caller owns cleanup.
     - Side effects: Reads installed files, temporarily leases immutable EPUB generations, and
       streams one archive beneath the configured temporary directory.
     - Throws: Missing payloads, unsafe paths or symbolic links, case/Unicode collisions, filesystem
       failures, or ZIP64 representation failures. A partially written archive is removed on every
       error.
     - Note: The Android manifest is always the literal first ZIP entry.
     */
    public func exportArchiveFile(moduleNames: Set<String>? = nil) throws -> AndroidModuleBackupFileExport {
        try exporter.exportArchiveFile(moduleNames: moduleNames)
    }

    /**
     Exports selected installed content in exact Android picker order.

     - Parameter orderedModuleNames: Runtime initials in the order shown by the picker.
     - Returns: Completed file-backed module backup owned by the caller.
     - Side effects: Enumerates and streams selected installed content into a temporary archive.
     - Throws: Discovery, cancellation, source-integrity, ZIP, or filesystem errors.
     */
    public func exportArchiveFile(
        orderedModuleNames: [String]
    ) throws -> AndroidModuleBackupFileExport {
        try exporter.exportArchiveFile(orderedModuleNames: orderedModuleNames)
    }

    /** Returns every Android-registerable installed family through the exporter's exact catalog. */
    public func installedContentCatalog() throws -> [AndroidModuleBackupInstalledContent] {
        try exporter.installedContentCatalog()
    }

    /** Builds a validated family plan and preserves the public backup-error contract. */
    private func planArchive(from data: Data) throws -> AndroidModuleBackupArchivePlan {
        do {
            return try archivePlanner.planArchive(from: data)
        } catch let error as AndroidModuleBackupArchivePlannerError {
            throw publicArchiveError(error)
        } catch {
            throw AndroidModuleBackupError.invalidArchive(error.localizedDescription)
        }
    }

    /** Builds a file-backed family plan and preserves the public backup-error contract. */
    private func planArchive(at archiveURL: URL) throws -> AndroidModuleBackupArchivePlan {
        do {
            return try archivePlanner.planArchive(at: archiveURL)
        } catch let error as AndroidModuleBackupArchivePlannerError {
            throw publicArchiveError(error)
        } catch {
            throw AndroidModuleBackupError.invalidArchive(error.localizedDescription)
        }
    }

    /** Converts planner failures into stable service-level failures used by import UI. */
    private func publicArchiveError(
        _ error: AndroidModuleBackupArchivePlannerError
    ) -> AndroidModuleBackupError {
        switch error {
        case .invalidArchive(let message):
            return .invalidArchive(message)
        case .malformedManifest:
            return .invalidManifest
        case .unsupportedBackupType(let type):
            return .unsupportedBackupType(type)
        case .unsupportedManifestVersion(let version):
            return .unsupportedManifestVersion(version)
        case .duplicateEntry(let path):
            return .duplicateEntry(path)
        case .unsupportedEntry(let path):
            if path.hasPrefix("mods.d/") || path.hasPrefix("modules/") {
                return .invalidModuleLayout("SWORD entry has no configuration owner: \(path).")
            }
            return .unsupportedModuleFormats([path])
        case .noModuleContent:
            return .noSupportedModules([])
        case .unsafeEntryPath(let path):
            return .invalidModuleLayout("Unsafe entry path \(path).")
        case .symbolicLink(let path):
            return .invalidModuleLayout("Symbolic-link entry \(path) is not installable.")
        case .destinationCollision(let first, let second):
            return .invalidModuleLayout("Archive destinations collide: \(first) and \(second).")
        case .resourceLimitExceeded(let resource, let limit, let actual):
            return .invalidArchive(
                "Archive exceeds \(resource.rawValue) limit \(limit) with \(actual)."
            )
        case .malformedSwordConfiguration(let path):
            return .invalidModuleLayout("Malformed SWORD configuration \(path).")
        case .unsafeSwordConfigurationDataPath(let path):
            return .invalidModuleLayout("Unsafe SWORD DataPath in \(path).")
        case .swordConfigurationNameMismatch(let path, let moduleName):
            return .invalidModuleLayout(
                "SWORD configuration \(path) does not match module initials \(moduleName)."
            )
        case .duplicateSwordModuleInitials(let moduleName):
            return .invalidModuleLayout("Duplicate SWORD module initials \(moduleName).")
        case .overlappingSwordOwnership(let first, let second):
            return .invalidModuleLayout(
                "SWORD configurations own overlapping payloads: \(first) and \(second)."
            )
        case .ambiguousSwordPayload(let path):
            return .invalidModuleLayout("SWORD payload has ambiguous ownership: \(path).")
        case .missingSwordPayload(let path):
            return .invalidModuleLayout("SWORD configuration \(path) has no owned payload.")
        }
    }

    /** Projects first-entry or legacy inference into the existing inspection value. */
    private func inspectionManifest(
        for plan: AndroidModuleBackupArchivePlan
    ) -> AndroidModuleBackupManifest {
        switch plan.manifestDisposition {
        case .validatedFirstEntry(let manifest):
            return AndroidModuleBackupManifest(
                backupType: manifest.backupType.rawValue,
                manifestVersion: manifest.manifestVersion,
                andBibleVersion: manifest.andBibleVersion
            )
        case .legacyManifestNotFirst, .legacyWithoutManifest:
            return AndroidModuleBackupManifest(
                backupType: AndroidModuleBackupArchiveType.moduleBackup.rawValue,
                manifestVersion: 1,
                andBibleVersion: nil
            )
        }
    }

    /** Allocates restore identities against the content the live Android-style runtime can open. */
    private func registrationPreview(
        for plan: AndroidModuleBackupArchivePlan
    ) throws -> AndroidModuleBackupRegistrationPreview {
        try AndroidModuleBackupRegistrationBuilder(
            moduleDirectory: moduleDirectory,
            fileManager: fileManager
        ).preview(
            plan: plan,
            installedContent: try installedRegistrationContentCatalog()
        )
    }

    /**
     Reads the same side-effect-free installed-book catalog used by export selection.

     - Returns: Android registration-order first winners across initials and full display names.
     - Side effects: Reads bounded config, SQLite, and published EPUB metadata only.
     - Throws: Cancellation. Malformed rows are omitted independently.
     */
    private func installedRegistrationContentCatalog() throws
        -> [AndroidModuleBackupInstalledContent] {
        try exporter.installedContentCatalog()
    }

    /** Returns one resolved source file's exact path relative to the module store. */
    private func moduleStoreRelativePath(for sourceURL: URL) -> String? {
        let root = moduleDirectory.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let source = sourceURL.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(prefix) else { return nil }
        return String(source.path.dropFirst(prefix.count))
    }

    /** Restores one validated plan through staging, format checks, and a durable exact overlay. */
    private func restorePlannedArchive(
        plan: AndroidModuleBackupArchivePlan,
        registrationPreview: AndroidModuleBackupRegistrationPreview,
        archiveSHA256: String,
        overwritePolicy: LocalSwordZipOverwritePolicy,
        extract: (AndroidModuleBackupPlannedEntry, URL) throws -> Void,
        verifyArchiveIdentity: () throws -> Void
    ) throws -> AndroidModuleBackupRestoreReport {
        try Task.checkCancellation()
        try requireStorageCapacity(
            estimatedAdditionalBytes: try estimatedRestoreBytes(
                plan: plan,
                registrationPreview: registrationPreview
            )
        )

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "android-module-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        for entry in plan.entries {
            try Task.checkCancellation()
            try extract(entry, stagingDirectory.appendingPathComponent(entry.relativePath))
        }
        let epubValidationRoot = temporaryDirectory.appendingPathComponent(
            "android-epub-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: epubValidationRoot) }
        let preparedRegistration = try AndroidModuleBackupRegistrationBuilder(
            moduleDirectory: moduleDirectory,
            fileManager: fileManager
        ).prepare(
            preview: registrationPreview,
            stagingDirectory: stagingDirectory,
            epubValidator: { payloadURL in
                _ = try EpubReader.installAndroidModuleBackup(
                    epubDirectoryURL: payloadURL,
                    libraryRootURL: epubValidationRoot
                )
            }
        )
        let acceptedPlan = acceptedRestorePlan(
            plan,
            preview: registrationPreview,
            prepared: preparedRegistration
        )
        let planningDiagnostics = plan.rejectedSwordConfigurationPaths.map { path in
            AndroidModuleBackupRestoreDiagnostic(
                family: .swordConfiguration,
                relativePath: path,
                message: "Malformed SWORD configuration was excluded from restore."
            )
        }
        let diagnostics = planningDiagnostics + preparedRegistration.diagnostics
        guard !acceptedPlan.entries.isEmpty,
              !preparedRegistration.archiveContent.isEmpty else {
            throw AndroidModuleBackupError.noSupportedModules(
                diagnostics.map(\.relativePath)
            )
        }
        let allPublishedPaths = acceptedPlan.entries.map(\.relativePath)
            + preparedRegistration.generatedConfigurationPaths
        let conflicts = try existingEntryPaths(for: allPublishedPaths)
        let authorizedPaths = try authorizedExistingPaths(
            policy: overwritePolicy,
            archiveSHA256: archiveSHA256,
            currentConflicts: conflicts
        )
        try verifyArchiveIdentity()
        try Task.checkCancellation()
        try publishAndroidRestore(
            plan: acceptedPlan,
            registration: preparedRegistration,
            from: stagingDirectory,
            authorizedExistingPaths: authorizedPaths
        )

        return AndroidModuleBackupRestoreReport(
            installedModuleNames: preparedRegistration.archiveContent.map(\.initials),
            installedEntryCount: acceptedPlan.entries.count,
            diagnostics: diagnostics
        )
    }

    /** Binds every eager ZIP payload to the exact source member retained by the plan. */
    private func inMemoryEntriesBySourcePath(_ data: Data) throws -> [String: ZipArchiveEntry] {
        let entries: [ZipArchiveEntry]
        do {
            entries = try ZipArchiveReader.entries(in: data)
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        }
        var result: [String: ZipArchiveEntry] = [:]
        for entry in entries {
            guard result.updateValue(entry, forKey: entry.name) == nil else {
                throw AndroidModuleBackupError.duplicateEntry(entry.name)
            }
        }
        return result
    }

    /** Binds every file-backed ZIP payload to the exact source member retained by the plan. */
    private func fileEntriesBySourcePath(at archiveURL: URL) throws -> [String: ZipArchiveFileEntry] {
        let entries: [ZipArchiveFileEntry]
        do {
            entries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        }
        var result: [String: ZipArchiveFileEntry] = [:]
        for entry in entries {
            guard result.updateValue(entry, forKey: entry.name) == nil else {
                throw AndroidModuleBackupError.duplicateEntry(entry.name)
            }
        }
        return result
    }

    /** Streams one archive digest and maps provider read errors into the public contract. */
    private func archiveDigest(at archiveURL: URL) throws -> String {
        do {
            return try ArchiveFingerprint.sha256Hex(at: archiveURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AndroidModuleBackupError.invalidArchive(
                "Unable to fingerprint the selected archive: \(error.localizedDescription)"
            )
        }
    }

    /**
     Filters staged archive entries to candidates that passed isolated family validation.

     - Parameters:
       - plan: Complete metadata-validated archive plan.
       - preview: Pre-extraction identity decisions, including accepted SWORD configurations.
       - prepared: Payload-validated raw-family registrations and diagnostics.
     - Returns: A plan containing only entries that may join the atomic live publication.
     - Side effects: none.
     - Failure modes: This deterministic projection cannot fail.
     */
    private func acceptedRestorePlan(
        _ plan: AndroidModuleBackupArchivePlan,
        preview: AndroidModuleBackupRegistrationPreview,
        prepared: AndroidModuleBackupPreparedRegistration
    ) -> AndroidModuleBackupArchivePlan {
        let acceptedSwordConfigurations = Set(preview.acceptedSwordConfigurationPaths)
        let acceptedEntries = plan.entries.filter { entry in
            switch entry.family {
            case .swordConfiguration:
                return acceptedSwordConfigurations.contains(entry.relativePath)
            case .swordPayload:
                return entry.owningConfigurationPaths.isEmpty
                    || entry.owningConfigurationPaths.contains {
                        acceptedSwordConfigurations.contains($0)
                    }
            case .epub:
                return prepared.candidates.contains { candidate in
                    candidate.family == .epub
                        && entry.relativePath.hasPrefix(candidate.relativePath + "/")
                }
            case .myBible, .mySword, .eSword, .ttf, .background, .prompts:
                return prepared.candidates.contains { candidate in
                    candidate.family == entry.family
                        && candidate.relativePath == entry.relativePath
                }
            }
        }
        var familyOrder: [AndroidModuleBackupContentFamily] = []
        var entriesByFamily: [AndroidModuleBackupContentFamily: [AndroidModuleBackupPlannedEntry]] = [:]
        for entry in acceptedEntries {
            if entriesByFamily[entry.family] == nil {
                familyOrder.append(entry.family)
            }
            entriesByFamily[entry.family, default: []].append(entry)
        }
        let swordEntries = plan.entries.filter { $0.family == .swordConfiguration }
        let acceptedSwordIndexes = swordEntries.indices.filter {
            acceptedSwordConfigurations.contains(swordEntries[$0].relativePath)
        }
        let acceptedSwordNames = acceptedSwordIndexes.map { plan.swordModuleNames[$0] }
        let acceptedSwordDisplayNames = acceptedSwordIndexes.map {
            plan.swordModuleDisplayNames[$0]
        }
        return AndroidModuleBackupArchivePlan(
            manifestDisposition: plan.manifestDisposition,
            entries: acceptedEntries,
            families: familyOrder.map {
                AndroidModuleBackupFamilyPlan(
                    family: $0,
                    entries: entriesByFamily[$0] ?? []
                )
            },
            swordModuleNames: acceptedSwordNames,
            swordModuleDisplayNames: acceptedSwordDisplayNames,
            rejectedSwordConfigurationPaths: plan.rejectedSwordConfigurationPaths,
            firstManifestFellBackToGenericInstall: plan.firstManifestFellBackToGenericInstall,
            conflictPaths: [],
            aggregateCompressedByteCount: acceptedEntries.reduce(0) {
                $0 + $1.compressedByteCount
            },
            aggregateExpandedByteCount: acceptedEntries.reduce(0) {
                $0 + $1.expandedByteCount
            }
        )
    }

    /** Returns unique direct `epub/<display name>` roots in archive order. */
    private func epubRelativeRoots(for plan: AndroidModuleBackupArchivePlan) -> [String] {
        var seen = Set<String>()
        return plan.entries.compactMap { entry in
            guard entry.family == .epub else { return nil }
            let components = entry.relativePath.split(separator: "/")
            guard components.count > 2 else { return nil }
            let root = components.prefix(2).joined(separator: "/")
            return seen.insert(root).inserted ? root : nil
        }
    }

    /// Android-supported manual background-image suffixes used by staged-family validation.
    private static let androidBackgroundImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp",
    ]

    /** Publishes all custom content before SWORD configuration activation files. */
    private func publishAndroidRestore(
        plan: AndroidModuleBackupArchivePlan,
        registration: AndroidModuleBackupPreparedRegistration,
        from stagingDirectory: URL,
        authorizedExistingPaths: Set<String>
    ) throws {
        let activationPaths = plan.entries.compactMap { entry in
            entry.family == .swordConfiguration ? entry.relativePath : nil
        } + registration.generatedConfigurationPaths
        let activationSet = Set(activationPaths)
        let contentPaths = plan.entries.map(\.relativePath).filter { !activationSet.contains($0) }
        let availability = AndroidModuleBackupRestoreAvailabilityTransaction(
            registration: registration,
            moduleDirectory: moduleDirectory,
            epubLibraryRootURL: epubLibraryRootURL,
            fileManager: fileManager
        )
        do {
            try mutationPublisher.publishExactOverlay(
                ModuleStoreExactOverlayManifest(
                    contentRelativePaths: contentPaths,
                    activationRelativePaths: activationPaths
                ),
                from: stagingDirectory,
                authorizedExistingPaths: authorizedExistingPaths,
                kind: .androidModuleBackup,
                validatePublishedState: {
                    try availability.validatePublishedState()
                },
                rollbackPublishedState: {
                    try availability.rollback()
                },
                completePublishedState: {
                    availability.complete()
                }
            )
        } catch ModuleStoreMutationError.destinationFilesExist(let paths) {
            throw AndroidModuleBackupError.moduleFilesAlreadyExist(paths)
        } catch ModuleStoreMutationError.destinationTypeConflict(let paths) {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Module destinations are not replaceable regular files: \(paths.joined(separator: ", "))"
            )
        }
    }

    /**
     Converts ZIP parser errors into concise archive messages for user-facing restore failures.
     */
    private static func archiveErrorMessage(for error: ZipArchiveReaderError) -> String {
        switch error {
        case .missingCentralDirectory:
            "Missing ZIP central directory."
        case .invalidArchive(let message):
            message
        case .unsupportedCompressionMethod(let method):
            "Unsupported ZIP compression method \(method)."
        case .decompressionFailed:
            "ZIP entry decompression failed."
        }
    }

    /**
     Validates occupied archive destinations and returns exact replaceable file conflicts.

     - Parameter relativePaths: Validated archive-relative file destinations.
     - Returns: Existing regular-file paths in deterministic order.
     - Side effects: Reads destination filesystem metadata.
     - Throws: `AndroidModuleBackupError.invalidModuleLayout` when an archive file targets a
       directory or symbolic link, matching Android's refusal to open that destination as a file.
     */
    private func existingEntryPaths(for relativePaths: [String]) throws -> [String] {
        var conflicts: [String] = []
        for relativePath in relativePaths {
            guard let existingURL = existingPublishedURL(for: relativePath) else { continue }
            let values = try existingURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Module destination is not a replaceable regular file: \(relativePath)"
                )
            }
            conflicts.append(relativePath)
        }
        return conflicts.sorted()
    }

    /**
     Sums advertised expanded entry sizes without allowing crafted ZIP64 metadata to overflow.

     - Parameter sizes: Uncompressed byte counts for every supported archive entry.
     - Returns: Signed byte estimate accepted by the shared storage preflight.
     - Side effects: none.
     - Throws: `AndroidModuleBackupError.invalidArchive` when one size or the aggregate exceeds
       `Int64`, preventing overflow from bypassing the capacity check.
     */
    private func estimatedExpandedBytes<S: Sequence>(for sizes: S) throws -> Int64
        where S.Element == UInt64 {
        var total: Int64 = 0
        for size in sizes {
            guard size <= UInt64(Int64.max) else {
                throw AndroidModuleBackupError.invalidArchive(
                    "ZIP entry size exceeds supported limits."
                )
            }
            let (next, overflow) = total.addingReportingOverflow(Int64(size))
            guard !overflow else {
                throw AndroidModuleBackupError.invalidArchive(
                    "ZIP expanded size exceeds supported limits."
                )
            }
            total = next
        }
        return total
    }

    /**
     Estimates peak restore bytes including native EPUB generations and generated registrations.

     The module staging/live duplication is applied by `requireStorageCapacity`. EPUB package bytes
     are added once more because native immutable generations copy the restored Android tree before
     commit. Generated configs use their enforced 64 KiB maximum rather than an archive payload cap.

     - Parameters:
       - plan: Validated archive entries and declared expanded sizes.
       - registrationPreview: Generated config and EPUB registration inventory.
     - Returns: Saturation-safe signed byte estimate for storage preflight.
     - Side effects: none.
     - Throws: `AndroidModuleBackupError.invalidArchive` when ZIP64 arithmetic exceeds `Int64`.
     */
    private func estimatedRestoreBytes(
        plan: AndroidModuleBackupArchivePlan,
        registrationPreview: AndroidModuleBackupRegistrationPreview
    ) throws -> Int64 {
        var total = try estimatedExpandedBytes(for: plan.entries.lazy.map(\.expandedByteCount))
        let epubBytes = try estimatedExpandedBytes(
            for: plan.entries.lazy.filter { $0.family == .epub }.map(\.expandedByteCount)
        )
        let configurationEstimate = Int64(registrationPreview.generatedConfigurationPaths.count)
            .multipliedReportingOverflow(by: 64 * 1_024)
        guard !configurationEstimate.overflow else {
            throw AndroidModuleBackupError.invalidArchive(
                "Generated registration storage estimate exceeds supported limits."
            )
        }
        for additional in [epubBytes, configurationEstimate.partialValue] {
            let (next, overflow) = total.addingReportingOverflow(additional)
            guard !overflow else {
                throw AndroidModuleBackupError.invalidArchive(
                    "Restore storage estimate exceeds supported limits."
                )
            }
            total = next
        }
        return total
    }

    /**
     Enforces Android's fixed reserve plus simultaneous staging and publication allocations.

     - Parameter estimatedAdditionalBytes: Validated expanded bytes needed for staging.
     - Side effects: Reads filesystem capacity metadata for the module and temporary roots.
     - Throws: `ModuleRepositoryError.insufficientStorage` when either reported volume cannot hold
       the shared reserve and its peak payload allocation. Missing capacity metadata fails open.
     */
    private func requireStorageCapacity(estimatedAdditionalBytes: Int64) throws {
        let moduleVolume = volumeIdentifier(for: moduleDirectory)
        let temporaryVolume = volumeIdentifier(for: temporaryDirectory)
        let rootsShareVolume = moduleVolume == nil
            || temporaryVolume == nil
            || moduleVolume == temporaryVolume
        let requiredAllocation: Int64
        if rootsShareVolume {
            let (doubled, overflow) = estimatedAdditionalBytes.multipliedReportingOverflow(by: 2)
            requiredAllocation = overflow ? Int64.max : doubled
        } else {
            requiredAllocation = estimatedAdditionalBytes
        }

        for destination in [moduleDirectory, temporaryDirectory] {
            guard let requirement = storagePreflight.requirement(
                for: destination,
                estimatedAdditionalBytes: requiredAllocation
            ), !requirement.isSatisfied else {
                continue
            }
            throw ModuleRepositoryError.insufficientStorage(
                requiredBytes: requirement.requiredBytes,
                availableBytes: requirement.availableBytes
            )
        }
    }

    /**
     Resolves a stable filesystem identifier for a destination that may not exist yet.

     - Parameter destination: Planned staging or live module path.
     - Returns: Filesystem number for the nearest existing ancestor, or `nil` when unavailable.
     - Side effects: Reads filesystem path and volume attributes.
     - Failure modes: Missing paths and attribute errors return `nil`; callers conservatively treat
       two unknown identifiers as the same volume.
     */
    private func volumeIdentifier(for destination: URL) -> UInt64? {
        var candidate = destination.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: candidate.path),
              let number = attributes[.systemNumber] as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }

    /**
     Validates archive-bound overwrite consent before staging an Android module backup.

     - Parameters:
       - policy: Strict rejection or consent retained from one read-only inspection.
       - archiveSHA256: Digest of the archive currently being restored.
       - currentConflicts: Exact live destinations currently occupied before staging.
     - Returns: Exact approved paths for revalidation under the module-store lease.
     - Side effects: none.
     - Throws: `AndroidModuleBackupError.moduleFilesAlreadyExist` for unapproved conflicts or
       `invalidArchive` when provider bytes changed after the user confirmed them.
     */
    private func authorizedExistingPaths(
        policy: LocalSwordZipOverwritePolicy,
        archiveSHA256: String,
        currentConflicts: [String]
    ) throws -> Set<String> {
        switch policy {
        case .reject:
            guard currentConflicts.isEmpty else {
                throw AndroidModuleBackupError.moduleFilesAlreadyExist(currentConflicts.sorted())
            }
            return []
        case .replaceExisting(let authorization):
            guard authorization.archiveSHA256 == archiveSHA256 else {
                throw AndroidModuleBackupError.invalidArchive(
                    "The selected archive changed after overwrite confirmation. Inspect it again before restoring."
                )
            }
            let approvedKeys = Set(authorization.conflictingPaths.map(filesystemCollisionKey))
            let unapproved = currentConflicts.filter { !approvedKeys.contains(filesystemCollisionKey($0)) }
            guard unapproved.isEmpty else {
                throw AndroidModuleBackupError.moduleFilesAlreadyExist(currentConflicts.sorted())
            }
            return Set(authorization.conflictingPaths)
        }
    }

    /**
     Finds an existing published module file that collides with one archive-relative path.

     The lookup walks the real directory entries instead of relying only on `fileExists(atPath:)`
     so case-variant Android paths can overwrite iOS-installed files reliably on APFS.
     */
    private func existingPublishedURL(for relativePath: String) -> URL? {
        var currentURL = moduleDirectory
        for rawComponent in relativePath.split(separator: "/") {
            let component = String(rawComponent)
            let componentKey = filesystemCollisionKey(component)
            if let childURLs = try? fileManager.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: nil
            ),
               let matchingURL = childURLs.first(where: { filesystemCollisionKey($0.lastPathComponent) == componentKey }) {
                currentURL = matchingURL
                continue
            }

            let exactURL = currentURL.appendingPathComponent(component)
            guard fileManager.fileExists(atPath: exactURL.path) else {
                return nil
            }
            currentURL = exactURL
        }
        return currentURL
    }

    /**
     Produces a conservative case-insensitive filesystem comparison key for one path component.
     */
    private func filesystemCollisionKey(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }


}
