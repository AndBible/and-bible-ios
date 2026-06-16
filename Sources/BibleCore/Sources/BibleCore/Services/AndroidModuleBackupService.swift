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

 The import UI uses this to distinguish supported SWORD payloads from Android-only formats and to
 decide whether the user should confirm overwriting files that already exist locally.
 */
public struct AndroidModuleBackupInspection: Sendable, Equatable {
    /// Decoded Android backup manifest.
    public let manifest: AndroidModuleBackupManifest

    /// Module initials derived from supported `mods.d/*.conf` entries.
    public let supportedModuleNames: [String]

    /// Number of supported SWORD file entries that would be written during restore.
    public let supportedEntryCount: Int

    /// Android module-backup entries that iOS recognizes but cannot restore through SWORD.
    public let unsupportedEntryPaths: [String]

    /// Supported SWORD entries whose destination files already exist locally.
    public let existingEntryPaths: [String]

    /// Whether the archive contains at least one restorable SWORD module.
    public var hasSupportedModules: Bool { !supportedModuleNames.isEmpty }

    /**
     Creates one archive inspection summary.

     - Parameters:
       - manifest: Decoded Android backup manifest.
       - supportedModuleNames: Restorable SWORD module initials.
       - supportedEntryCount: Number of supported SWORD file entries.
       - unsupportedEntryPaths: Recognized Android-only entry paths.
       - existingEntryPaths: Supported paths that already exist in the local module directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        manifest: AndroidModuleBackupManifest,
        supportedModuleNames: [String],
        supportedEntryCount: Int,
        unsupportedEntryPaths: [String],
        existingEntryPaths: [String]
    ) {
        self.manifest = manifest
        self.supportedModuleNames = supportedModuleNames
        self.supportedEntryCount = supportedEntryCount
        self.unsupportedEntryPaths = unsupportedEntryPaths
        self.existingEntryPaths = existingEntryPaths
    }
}

/**
 Summary returned after installing supported content from an Android module backup.
 */
public struct AndroidModuleBackupRestoreReport: Sendable, Equatable {
    /// Installed SWORD module initials.
    public let installedModuleNames: [String]

    /// Count of supported SWORD file entries written into the local module directory.
    public let installedEntryCount: Int

    /// Android-only backup entries skipped because iOS cannot restore them through SWORD.
    public let skippedUnsupportedEntryPaths: [String]

    /**
     Creates one restore report.

     - Parameters:
       - installedModuleNames: Installed SWORD module initials.
       - installedEntryCount: Number of supported file entries written.
       - skippedUnsupportedEntryPaths: Recognized Android-only entries that were skipped.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        installedModuleNames: [String],
        installedEntryCount: Int,
        skippedUnsupportedEntryPaths: [String]
    ) {
        self.installedModuleNames = installedModuleNames
        self.installedEntryCount = installedEntryCount
        self.skippedUnsupportedEntryPaths = skippedUnsupportedEntryPaths
    }
}

/**
 Android-compatible module backup archive produced from locally installed SWORD modules.
 */
public struct AndroidModuleBackupExport: Sendable, Equatable {
    /// Android-compatible export filename.
    public let fileName: String

    /// Raw `.abmd.zip` archive bytes.
    public let data: Data

    /// Exported SWORD module initials.
    public let moduleNames: [String]

    /// Number of file entries written into the ZIP, including the manifest.
    public let entryCount: Int

    /**
     Creates one module backup export result.

     - Parameters:
       - fileName: Android-compatible backup filename.
       - data: Raw ZIP archive bytes.
       - moduleNames: Exported SWORD module initials.
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

    /// The archive's supported SWORD entries are incomplete or inconsistent.
    case invalidModuleLayout(String)

    /// The archive contains a duplicate file entry.
    case duplicateEntry(String)

    /// Restore was asked not to overwrite existing files and matching module paths already exist.
    case moduleFilesAlreadyExist([String])

    /// No installed SWORD modules were available for Android-compatible export.
    case noExportableModules

    /// An installed module config references data files that are missing locally.
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
                return "No supported SWORD modules were found in this Android module backup."
            }
            return "This Android module backup only contains formats iOS cannot restore yet: \(paths.prefix(5).joined(separator: ", "))"
        case .invalidModuleLayout(let message):
            return "Invalid Android module backup layout: \(message)"
        case .duplicateEntry(let name):
            return "Android module backup contains duplicate entry \(name)."
        case .moduleFilesAlreadyExist(let files):
            return "Module files already exist: \(files.prefix(5).joined(separator: ", "))"
        case .noExportableModules:
            return "No installed SWORD modules are available for Android-compatible export."
        case .missingExportData(let moduleName, let dataPath):
            return "Cannot export \(moduleName) because its data files are missing at \(dataPath)."
        }
    }
}

/**
 Loads Android `.abmd.zip` archives and exports installed SWORD modules in Android's backup shape.

 Android module backups contain a `MODULE_BACKUP` manifest and raw files relative to Android's
 modules directory. iOS supports the shared SWORD portion of that format (`mods.d/` plus
 `modules/`) and reports Android-only payloads (`mybible/`, `mysword/`, `esword/`, `epub/`) as
 skipped instead of pretending they were restored.
 */
public final class AndroidModuleBackupService {
    /// Android module backup suffix used for file recognition.
    public static let moduleBackupSuffix = ".abmd.zip"

    /// Android's default module backup filename.
    public static let moduleBackupFileName = "AndBibleModulesBackup.abmd.zip"

    /// Android backup manifest entry name.
    private static let manifestFileName = "AndBibleBackupManifest.json"

    /// Android-only module backup prefixes that iOS recognizes but cannot restore as SWORD.
    private static let unsupportedAndroidModulePrefixes = ["mybible/", "mysword/", "esword/", "epub/"]

    /// SWORD drivers whose `DataPath` points at a file stem inside the actual module directory.
    private static let singleFileDataPathDrivers: Set<String> = ["rawld", "zld", "rawgenbook", "rawfiles"]

    /// Largest manifest or SWORD config entry accepted for in-memory metadata parsing.
    private static let maximumMetadataEntryByteCount = 1024 * 1024

    private let fileManager: FileManager
    private let moduleDirectory: URL
    private let temporaryDirectory: URL

    /**
     Creates an Android module backup service.

     - Parameters:
       - fileManager: File manager used for module file reads/writes and temporary staging.
       - moduleDirectory: Local SWORD module root. Defaults to `SwordManager.defaultModulePath()`.
       - temporaryDirectory: Scratch directory for staged restores and rollback backups.
     - Side effects: Ensures the module root and `mods.d` directory exist.
     - Failure modes: Directory creation failures are deferred until import/export operations.
     */
    public init(
        fileManager: FileManager = .default,
        moduleDirectory: URL? = nil,
        temporaryDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.moduleDirectory = moduleDirectory
            ?? URL(fileURLWithPath: SwordManager.defaultModulePath(), isDirectory: true)
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: self.moduleDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: self.moduleDirectory.appendingPathComponent("mods.d", isDirectory: true),
            withIntermediateDirectories: true
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
     Reads an Android module backup without mutating local module files.

     - Parameter data: Raw `.abmd.zip` archive bytes.
     - Returns: Summary of supported modules, unsupported Android-only entries, and existing files.
     - Side effects: Reads ZIP data and local file-existence state; no files are written.
     - Throws: `AndroidModuleBackupError` for malformed archives, wrong backup types, unsupported
       manifest versions, duplicate entries, or incomplete SWORD module layouts.
     */
    public func inspectArchive(from data: Data) throws -> AndroidModuleBackupInspection {
        let archive = try loadClassifiedArchive(from: data)
        let existingPaths = existingEntryPaths(in: archive.supportedEntries)
        return AndroidModuleBackupInspection(
            manifest: archive.manifest,
            supportedModuleNames: archive.moduleNames,
            supportedEntryCount: archive.supportedEntries.count,
            unsupportedEntryPaths: archive.unsupportedEntryPaths,
            existingEntryPaths: existingPaths
        )
    }

    /**
     Reads an Android module backup from a file URL without mutating local module files.

     - Parameter archiveURL: File URL for a `.abmd.zip` archive.
     - Returns: Summary of supported modules, unsupported Android-only entries, and existing files.
     - Side effects: Reads ZIP metadata and small manifest/config entries; no module files are
       written.
     - Throws: `AndroidModuleBackupError` for malformed archives, wrong backup types, unsupported
       manifest versions, duplicate entries, or incomplete SWORD module layouts.
     */
    public func inspectArchive(fromArchiveAt archiveURL: URL) throws -> AndroidModuleBackupInspection {
        let archive = try loadClassifiedArchive(fromArchiveAt: archiveURL)
        let existingPaths = existingEntryPaths(in: archive.supportedEntries)
        return AndroidModuleBackupInspection(
            manifest: archive.manifest,
            supportedModuleNames: archive.moduleNames,
            supportedEntryCount: archive.supportedEntries.count,
            unsupportedEntryPaths: archive.unsupportedEntryPaths,
            existingEntryPaths: existingPaths
        )
    }

    /**
     Installs supported SWORD content from an Android module backup.

     - Parameters:
       - data: Raw `.abmd.zip` archive bytes.
       - allowOverwritingExistingFiles: Whether existing local module files may be replaced.
     - Returns: Installed module names and skipped unsupported Android-only entries.
     - Side effects:
       - writes supported `mods.d/` and `modules/` entries into the local SWORD module directory
       - stages files first, then uses rollback backups for overwritten files during publish
       - deletes SWORD's `modules-conf.cache` so the next manager scan sees restored modules
     - Throws: `AndroidModuleBackupError` for invalid archives, unsupported-only content, or
       existing files when overwrite is disabled; rethrows file-system failures during staging or
       publish after attempting rollback.
     */
    public func restoreArchive(
        from data: Data,
        allowOverwritingExistingFiles: Bool = true
    ) throws -> AndroidModuleBackupRestoreReport {
        let archive = try loadClassifiedArchive(from: data)
        let existingPaths = existingEntryPaths(in: archive.supportedEntries)
        if !allowOverwritingExistingFiles, !existingPaths.isEmpty {
            throw AndroidModuleBackupError.moduleFilesAlreadyExist(existingPaths)
        }

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "android-module-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let rollbackDirectory = temporaryDirectory.appendingPathComponent(
            "android-module-backup-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: rollbackDirectory)
        }

        for entry in archive.supportedEntries {
            let destinationURL = stagingDirectory.appendingPathComponent(entry.name)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destinationURL, options: .atomic)
        }

        try publishStagedEntries(
            archive.supportedEntries.map(\.name),
            from: stagingDirectory,
            rollbackDirectory: rollbackDirectory
        )
        invalidateModuleCache()

        return AndroidModuleBackupRestoreReport(
            installedModuleNames: archive.moduleNames,
            installedEntryCount: archive.supportedEntries.count,
            skippedUnsupportedEntryPaths: archive.unsupportedEntryPaths
        )
    }

    /**
     Installs supported SWORD content from a file-backed Android module backup.

     - Parameters:
       - archiveURL: File URL for a `.abmd.zip` archive.
       - allowOverwritingExistingFiles: Whether existing local module files may be replaced.
     - Returns: Installed module names and skipped unsupported Android-only entries.
     - Side effects:
       - streams supported `mods.d/` and `modules/` entries into staging
       - publishes staged files into the local SWORD module directory with rollback backups
       - deletes SWORD's `modules-conf.cache` so the next manager scan sees restored modules
     - Throws: `AndroidModuleBackupError` for invalid archives, unsupported-only content, or
       existing files when overwrite is disabled; rethrows file-system failures during staging or
       publish after attempting rollback.
     */
    public func restoreArchive(
        fromArchiveAt archiveURL: URL,
        allowOverwritingExistingFiles: Bool = true
    ) throws -> AndroidModuleBackupRestoreReport {
        let archive = try loadClassifiedArchive(fromArchiveAt: archiveURL)
        let existingPaths = existingEntryPaths(in: archive.supportedEntries)
        if !allowOverwritingExistingFiles, !existingPaths.isEmpty {
            throw AndroidModuleBackupError.moduleFilesAlreadyExist(existingPaths)
        }

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "android-module-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let rollbackDirectory = temporaryDirectory.appendingPathComponent(
            "android-module-backup-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: rollbackDirectory)
        }

        for entry in archive.supportedEntries {
            let destinationURL = stagingDirectory.appendingPathComponent(entry.name)
            do {
                try ZipArchiveReader.extract(
                    entry.source,
                    fromArchiveAt: archiveURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            } catch let error as ZipArchiveReaderError {
                throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
            }
        }

        try publishStagedEntries(
            archive.supportedEntries.map(\.name),
            from: stagingDirectory,
            rollbackDirectory: rollbackDirectory
        )
        invalidateModuleCache()

        return AndroidModuleBackupRestoreReport(
            installedModuleNames: archive.moduleNames,
            installedEntryCount: archive.supportedEntries.count,
            skippedUnsupportedEntryPaths: archive.unsupportedEntryPaths
        )
    }

    /**
     Exports installed SWORD modules using Android's `.abmd.zip` backup layout.

     - Parameter moduleNames: Optional module initials to export. When omitted, all installed SWORD
       configs under `mods.d/` are exported.
     - Returns: Android-compatible module backup bytes and exported module names.
     - Side effects: Reads installed module config/data files from the local SWORD module directory.
     - Throws: `AndroidModuleBackupError.noExportableModules` when no supported SWORD module files
       are present; `AndroidModuleBackupError.missingExportData` when a config points at missing
       data; `ZipArchiveWriterError` when the archive exceeds non-ZIP64 limits.
     */
    public func exportArchive(moduleNames: Set<String>? = nil) throws -> AndroidModuleBackupExport {
        let manifestData = Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":1}"#.utf8)
        var entries: [ZipArchiveWriterEntry] = [
            ZipArchiveWriterEntry(name: Self.manifestFileName, data: manifestData),
        ]
        var exportedModuleNames: [String] = []
        var seenEntryNames: Set<String> = [Self.manifestFileName]

        let configs = try installedModuleConfigs(filteredBy: moduleNames)
        guard !configs.isEmpty else {
            throw AndroidModuleBackupError.noExportableModules
        }

        for config in configs {
            let confArchivePath = try archivePath(for: config.fileURL)
            if seenEntryNames.insert(confArchivePath).inserted {
                entries.append(ZipArchiveWriterEntry(name: confArchivePath, data: try Data(contentsOf: config.fileURL)))
            }

            let dataRoot = dataDirectoryURL(for: config)
            guard fileManager.fileExists(atPath: dataRoot.path) else {
                throw AndroidModuleBackupError.missingExportData(
                    moduleName: config.moduleName,
                    dataPath: config.dataPath
                )
            }

            for fileURL in try regularFiles(under: dataRoot) {
                let archivePath = try archivePath(for: fileURL)
                guard seenEntryNames.insert(archivePath).inserted else { continue }
                entries.append(ZipArchiveWriterEntry(name: archivePath, data: try Data(contentsOf: fileURL)))
            }
            exportedModuleNames.append(config.moduleName)
        }

        guard entries.count > 1 else {
            throw AndroidModuleBackupError.noExportableModules
        }
        let archiveData = try ZipArchiveWriter.storedArchive(entries: entries)
        return AndroidModuleBackupExport(
            fileName: Self.moduleBackupFileName,
            data: archiveData,
            moduleNames: exportedModuleNames.sorted(),
            entryCount: entries.count
        )
    }

    /**
     Parses and classifies an Android module backup into supported and unsupported entry groups.
     */
    private func loadClassifiedArchive(from data: Data) throws -> ClassifiedArchive {
        let entries: [ZipArchiveEntry]
        do {
            entries = try ZipArchiveReader.entries(in: data)
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        } catch {
            throw AndroidModuleBackupError.invalidArchive(error.localizedDescription)
        }

        let normalizedEntries = try entries.map { entry in
            ZipArchiveEntry(name: try normalizedArchivePath(entry.name), data: entry.data)
        }

        var normalizedNames: Set<String> = []
        for entry in normalizedEntries {
            let collisionKey = entry.name.lowercased()
            guard normalizedNames.insert(collisionKey).inserted else {
                throw AndroidModuleBackupError.duplicateEntry(entry.name)
            }
        }

        let manifestName = Self.manifestFileName.lowercased()
        guard let manifestEntry = normalizedEntries.first(where: { $0.name.lowercased() == manifestName }) else {
            throw AndroidModuleBackupError.missingManifest
        }
        let manifest = try decodeManifest(from: manifestEntry.data)
        guard manifest.backupType == "MODULE_BACKUP" else {
            throw AndroidModuleBackupError.unsupportedBackupType(manifest.backupType)
        }
        guard manifest.manifestVersion <= 1 else {
            throw AndroidModuleBackupError.unsupportedManifestVersion(manifest.manifestVersion)
        }

        var supportedEntries: [ZipArchiveEntry] = []
        var unsupportedEntryPaths: [String] = []
        for entry in normalizedEntries where entry.name.lowercased() != manifestName {
            let normalizedPath = entry.name
            let lowercasedPath = normalizedPath.lowercased()
            if isSupportedSwordEntry(lowercasedPath) {
                supportedEntries.append(ZipArchiveEntry(name: normalizedPath, data: entry.data))
            } else if Self.unsupportedAndroidModulePrefixes.contains(where: lowercasedPath.hasPrefix) {
                unsupportedEntryPaths.append(normalizedPath)
            } else {
                throw AndroidModuleBackupError.invalidModuleLayout("Unsupported entry \(normalizedPath).")
            }
        }

        let moduleNames = try supportedModuleNames(in: supportedEntries, unsupportedEntryPaths: unsupportedEntryPaths)
        return ClassifiedArchive(
            manifest: manifest,
            supportedEntries: supportedEntries,
            unsupportedEntryPaths: unsupportedEntryPaths.sorted(),
            moduleNames: moduleNames
        )
    }

    /**
     Parses and classifies a file-backed Android module backup into supported and unsupported groups.
     */
    private func loadClassifiedArchive(fromArchiveAt archiveURL: URL) throws -> ClassifiedFileArchive {
        let entries: [ZipArchiveFileEntry]
        do {
            entries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        } catch {
            throw AndroidModuleBackupError.invalidArchive(error.localizedDescription)
        }

        let normalizedEntries = try entries.map { entry in
            ClassifiedFileEntry(name: try normalizedArchivePath(entry.name), source: entry)
        }

        var normalizedNames: Set<String> = []
        for entry in normalizedEntries {
            let collisionKey = entry.name.lowercased()
            guard normalizedNames.insert(collisionKey).inserted else {
                throw AndroidModuleBackupError.duplicateEntry(entry.name)
            }
        }

        let manifestName = Self.manifestFileName.lowercased()
        guard let manifestEntry = normalizedEntries.first(where: { $0.name.lowercased() == manifestName }) else {
            throw AndroidModuleBackupError.missingManifest
        }
        let manifest = try decodeManifest(
            from: fileBackedEntryData(manifestEntry.source, fromArchiveAt: archiveURL)
        )
        guard manifest.backupType == "MODULE_BACKUP" else {
            throw AndroidModuleBackupError.unsupportedBackupType(manifest.backupType)
        }
        guard manifest.manifestVersion <= 1 else {
            throw AndroidModuleBackupError.unsupportedManifestVersion(manifest.manifestVersion)
        }

        var supportedEntries: [ClassifiedFileEntry] = []
        var unsupportedEntryPaths: [String] = []
        for entry in normalizedEntries where entry.name.lowercased() != manifestName {
            let normalizedPath = entry.name
            let lowercasedPath = normalizedPath.lowercased()
            if isSupportedSwordEntry(lowercasedPath) {
                supportedEntries.append(ClassifiedFileEntry(name: normalizedPath, source: entry.source))
            } else if Self.unsupportedAndroidModulePrefixes.contains(where: lowercasedPath.hasPrefix) {
                unsupportedEntryPaths.append(normalizedPath)
            } else {
                throw AndroidModuleBackupError.invalidModuleLayout("Unsupported entry \(normalizedPath).")
            }
        }

        let moduleNames = try supportedModuleNames(
            in: supportedEntries,
            unsupportedEntryPaths: unsupportedEntryPaths,
            archiveURL: archiveURL
        )
        return ClassifiedFileArchive(
            manifest: manifest,
            supportedEntries: supportedEntries,
            unsupportedEntryPaths: unsupportedEntryPaths.sorted(),
            moduleNames: moduleNames
        )
    }

    /**
     Decodes Android's backup manifest while preserving Android defaults for omitted fields.
     */
    private func decodeManifest(from data: Data) throws -> AndroidModuleBackupManifest {
        do {
            let dto = try JSONDecoder().decode(ManifestDTO.self, from: data)
            return AndroidModuleBackupManifest(
                backupType: dto.backupType,
                manifestVersion: dto.manifestVersion ?? 1,
                andBibleVersion: dto.andBibleVersion
            )
        } catch {
            throw AndroidModuleBackupError.invalidManifest
        }
    }

    /**
     Reads one small metadata entry from a file-backed module backup.
     */
    private func fileBackedEntryData(_ entry: ZipArchiveFileEntry, fromArchiveAt archiveURL: URL) throws -> Data {
        do {
            return try ZipArchiveReader.data(
                for: entry,
                inArchiveAt: archiveURL,
                maximumByteCount: Self.maximumMetadataEntryByteCount,
                fileManager: fileManager
            )
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        } catch {
            throw AndroidModuleBackupError.invalidArchive(error.localizedDescription)
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
     Normalizes and validates one archive entry path before it is used for local file I/O.
     */
    private func normalizedArchivePath(_ rawPath: String) throws -> String {
        var path = rawPath.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/") else {
            throw AndroidModuleBackupError.invalidModuleLayout("Unsafe entry path \(rawPath).")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw AndroidModuleBackupError.invalidModuleLayout("Unsafe entry path \(rawPath).")
        }
        return path
    }

    /**
     Determines whether a normalized lowercase path belongs to the shared SWORD module layout.
     */
    private func isSupportedSwordEntry(_ lowercasedPath: String) -> Bool {
        if lowercasedPath.hasPrefix("modules/") {
            return true
        }
        return lowercasedPath.hasPrefix("mods.d/") && lowercasedPath.hasSuffix(".conf")
    }

    /**
     Validates supported SWORD entries and returns module initials in Android install order.
     */
    private func supportedModuleNames(
        in supportedEntries: [ZipArchiveEntry],
        unsupportedEntryPaths: [String]
    ) throws -> [String] {
        guard !supportedEntries.isEmpty else {
            throw AndroidModuleBackupError.noSupportedModules(unsupportedEntryPaths.sorted())
        }

        let confEntries = supportedEntries.filter { entry in
            let lowercasedPath = entry.name.lowercased()
            return lowercasedPath.hasPrefix("mods.d/") && lowercasedPath.hasSuffix(".conf")
        }
        guard !confEntries.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout("No module .conf files found in mods.d/.")
        }
        let dataEntryNames = Set(
            supportedEntries.map(\.name).filter { $0.lowercased().hasPrefix("modules/") }
        )
        guard !dataEntryNames.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout("No module data files found in modules/.")
        }

        var moduleNames: [String] = []
        for entry in confEntries {
            let config = try parseModuleConfig(data: entry.data, fallbackPath: entry.name)
            let expectedDataRoot = dataDirectoryPath(for: config)
            let hasData = dataEntryNames.contains { entryName in
                entryName == expectedDataRoot || entryName.hasPrefix("\(expectedDataRoot)/")
            }
            guard hasData else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "\(config.moduleName) references missing data path \(expectedDataRoot)."
                )
            }
            moduleNames.append(config.moduleName)
        }
        return moduleNames
    }

    /**
     Validates file-backed supported SWORD entries and returns module initials.
     */
    private func supportedModuleNames(
        in supportedEntries: [ClassifiedFileEntry],
        unsupportedEntryPaths: [String],
        archiveURL: URL
    ) throws -> [String] {
        guard !supportedEntries.isEmpty else {
            throw AndroidModuleBackupError.noSupportedModules(unsupportedEntryPaths.sorted())
        }

        let confEntries = supportedEntries.filter { entry in
            let lowercasedPath = entry.name.lowercased()
            return lowercasedPath.hasPrefix("mods.d/") && lowercasedPath.hasSuffix(".conf")
        }
        guard !confEntries.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout("No module .conf files found in mods.d/.")
        }
        let dataEntryNames = Set(
            supportedEntries.map(\.name).filter { $0.lowercased().hasPrefix("modules/") }
        )
        guard !dataEntryNames.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout("No module data files found in modules/.")
        }

        var moduleNames: [String] = []
        for entry in confEntries {
            let configData = try fileBackedEntryData(entry.source, fromArchiveAt: archiveURL)
            let config = try parseModuleConfig(data: configData, fallbackPath: entry.name)
            let expectedDataRoot = dataDirectoryPath(for: config)
            let hasData = dataEntryNames.contains { entryName in
                entryName == expectedDataRoot || entryName.hasPrefix("\(expectedDataRoot)/")
            }
            guard hasData else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "\(config.moduleName) references missing data path \(expectedDataRoot)."
                )
            }
            moduleNames.append(config.moduleName)
        }
        return moduleNames
    }

    /**
     Finds supported archive paths that would overwrite existing local module files.
     */
    private func existingEntryPaths(in supportedEntries: [ZipArchiveEntry]) -> [String] {
        supportedEntries.map(\.name)
            .filter { fileManager.fileExists(atPath: moduleDirectory.appendingPathComponent($0).path) }
            .sorted()
    }

    /**
     Finds file-backed supported archive paths that would overwrite existing local module files.
     */
    private func existingEntryPaths(in supportedEntries: [ClassifiedFileEntry]) -> [String] {
        supportedEntries.map(\.name)
            .filter { fileManager.fileExists(atPath: moduleDirectory.appendingPathComponent($0).path) }
            .sorted()
    }

    /**
     Atomically publishes staged module files with rollback protection for overwritten paths.
     */
    private func publishStagedEntries(
        _ relativePaths: [String],
        from stagingDirectory: URL,
        rollbackDirectory: URL
    ) throws {
        var movedExistingPaths: [String] = []
        var createdPaths: [String] = []

        do {
            for relativePath in relativePaths {
                let finalURL = moduleDirectory.appendingPathComponent(relativePath)
                let stagedURL = stagingDirectory.appendingPathComponent(relativePath)
                let rollbackURL = rollbackDirectory.appendingPathComponent(relativePath)
                try fileManager.createDirectory(
                    at: finalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.createDirectory(
                        at: rollbackURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: finalURL, to: rollbackURL)
                    movedExistingPaths.append(relativePath)
                }

                try fileManager.copyItem(at: stagedURL, to: finalURL)
                createdPaths.append(relativePath)
            }
        } catch {
            for relativePath in createdPaths.reversed() {
                try? fileManager.removeItem(at: moduleDirectory.appendingPathComponent(relativePath))
            }
            for relativePath in movedExistingPaths.reversed() {
                let finalURL = moduleDirectory.appendingPathComponent(relativePath)
                let rollbackURL = rollbackDirectory.appendingPathComponent(relativePath)
                try? fileManager.createDirectory(
                    at: finalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fileManager.moveItem(at: rollbackURL, to: finalURL)
            }
            throw error
        }
    }

    /**
     Removes SWORD's module cache after installing files outside `ModuleRepository`.
     */
    private func invalidateModuleCache() {
        let cacheURL = moduleDirectory
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("modules-conf.cache")
        try? fileManager.removeItem(at: cacheURL)
    }

    /**
     Loads installed SWORD config files and filters them by optional module initials.
     */
    private func installedModuleConfigs(filteredBy moduleNames: Set<String>?) throws -> [ModuleConfig] {
        let requestedNames = moduleNames.map { Set($0.map { $0.uppercased() }) }
        let modsDirectory = moduleDirectory.appendingPathComponent("mods.d", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: modsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try files
            .filter { $0.pathExtension.lowercased() == "conf" }
            .compactMap { url -> ModuleConfig? in
                let data = try Data(contentsOf: url)
                let config = try parseModuleConfig(data: data, fallbackPath: url.path)
                guard requestedNames?.contains(config.moduleName.uppercased()) ?? true else {
                    return nil
                }
                return ModuleConfig(
                    moduleName: config.moduleName,
                    dataPath: config.dataPath,
                    modDrv: config.modDrv,
                    fileURL: url
                )
            }
            .sorted { $0.moduleName.localizedCaseInsensitiveCompare($1.moduleName) == .orderedAscending }
    }

    /**
     Parses the SWORD config fields needed for Android backup restore/export validation.
     */
    private func parseModuleConfig(data: Data, fallbackPath: String) throws -> ModuleConfig {
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw AndroidModuleBackupError.invalidModuleLayout("\(fallbackPath) is not a readable SWORD config.")
        }

        var sectionName: String?
        var dataPath: String?
        var modDrv: String?
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["),
               line.hasSuffix("]"),
               line.count > 2,
               sectionName == nil {
                sectionName = String(line.dropFirst().dropLast())
                continue
            }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "datapath" {
                dataPath = value
            } else if key == "moddrv" {
                modDrv = value
            }
        }

        let fallbackName = ((fallbackPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let moduleName = (sectionName?.isEmpty == false ? sectionName : fallbackName) ?? fallbackName
        guard let dataPath, !dataPath.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout("\(moduleName) is missing DataPath.")
        }
        let normalizedDataPath = try normalizedDataPath(dataPath, moduleName: moduleName)
        return ModuleConfig(
            moduleName: moduleName.uppercased(),
            dataPath: normalizedDataPath,
            modDrv: modDrv?.lowercased() ?? "",
            fileURL: URL(fileURLWithPath: fallbackPath)
        )
    }

    /**
     Normalizes a SWORD `DataPath` value to an archive-relative path.
     */
    private func normalizedDataPath(_ rawDataPath: String, moduleName: String) throws -> String {
        var path = rawDataPath.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") {
            path = String(path.dropFirst(2))
        }
        while path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        while path.hasSuffix("/") {
            path = String(path.dropLast())
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !components.contains(where: { $0 == ".." || $0.isEmpty }),
              path.lowercased().hasPrefix("modules/") else {
            throw AndroidModuleBackupError.invalidModuleLayout("\(moduleName) has unsupported DataPath \(rawDataPath).")
        }
        return path
    }

    /**
     Returns the archive data directory path for a parsed module config.
     */
    private func dataDirectoryPath(for config: ModuleConfig) -> String {
        guard Self.singleFileDataPathDrivers.contains(config.modDrv),
              let slashIndex = config.dataPath.lastIndex(of: "/") else {
            return config.dataPath
        }
        return String(config.dataPath[..<slashIndex])
    }

    /**
     Returns the local data directory URL for a parsed module config.
     */
    private func dataDirectoryURL(for config: ModuleConfig) -> URL {
        moduleDirectory.appendingPathComponent(dataDirectoryPath(for: config), isDirectory: true)
    }

    /**
     Lists regular files below one local file or directory in deterministic archive order.
     */
    private func regularFiles(under url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return [url]
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    /**
     Converts a local module file URL into an Android module-backup archive path.
     */
    private func archivePath(for fileURL: URL) throws -> String {
        let rootPath = moduleDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix("\(rootPath)/") else {
            throw AndroidModuleBackupError.invalidModuleLayout("\(fileURL.path) is outside the module directory.")
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /**
     Private DTO for Android's manifest JSON.
     */
    private struct ManifestDTO: Decodable {
        /// Required backup type string.
        let backupType: String

        /// Optional manifest version; Android defaults to `1`.
        let manifestVersion: Int?

        /// Optional Android app version.
        let andBibleVersion: Int?
    }

    /**
     Parsed SWORD module config fields used by backup restore/export.
     */
    private struct ModuleConfig {
        /// Module initials from the config section or config filename.
        let moduleName: String

        /// Normalized archive-relative `DataPath`.
        let dataPath: String

        /// Lowercased SWORD driver name.
        let modDrv: String

        /// Local config file URL for export, or fallback URL used during archive validation.
        let fileURL: URL
    }

    /**
     Classified, validated archive entries used internally by inspection and restore.
     */
    private struct ClassifiedArchive {
        /// Decoded Android manifest.
        let manifest: AndroidModuleBackupManifest

        /// Supported SWORD entries safe to write under the local module directory.
        let supportedEntries: [ZipArchiveEntry]

        /// Recognized Android-only entries that iOS skips.
        let unsupportedEntryPaths: [String]

        /// Module initials derived from supported config entries.
        let moduleNames: [String]
    }

    /**
     Normalized file-backed ZIP entry used internally by inspection and restore.
     */
    private struct ClassifiedFileEntry {
        /// Normalized archive-relative path safe to publish under the module directory.
        let name: String

        /// Original file-backed ZIP entry descriptor used for streaming extraction.
        let source: ZipArchiveFileEntry
    }

    /**
     Classified, validated file-backed archive entries used internally by inspection and restore.
     */
    private struct ClassifiedFileArchive {
        /// Decoded Android manifest.
        let manifest: AndroidModuleBackupManifest

        /// Supported SWORD entries safe to write under the local module directory.
        let supportedEntries: [ClassifiedFileEntry]

        /// Recognized Android-only entries that iOS skips.
        let unsupportedEntryPaths: [String]

        /// Module initials derived from supported config entries.
        let moduleNames: [String]
    }
}
