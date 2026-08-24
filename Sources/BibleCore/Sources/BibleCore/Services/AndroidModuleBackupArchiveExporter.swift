// AndroidModuleBackupArchiveExporter.swift — Manifest-first Android module backup ZIP creation

import Foundation

/**
 Creates Android-compatible module backup archives from a validated file-backed inventory.

 The exporter is the sole owner of ZIP ordering and temporary archive lifecycle. It writes the
 Android manifest as the literal first member, streams every payload from disk, and retains native
 EPUB generations through the complete write. Discovery and ownership rules remain isolated in
 `AndroidModuleBackupExportInventoryBuilder`.
 */
internal final class AndroidModuleBackupArchiveExporter {
    /// Android's required literal first ZIP member for module backups.
    private static let manifestFileName = AndroidBackupManifestCodec.fileName

    /// File manager used for archive writes, compatibility reads, and cleanup.
    private let fileManager: FileManager

    /// Directory that owns temporary completed and partial archive files.
    private let temporaryDirectory: URL

    /// Cross-family inventory builder used before the ZIP destination is opened.
    private let inventoryBuilder: AndroidModuleBackupExportInventoryBuilder

    /**
     Creates an archive exporter bound to one installed-module layout.

     - Parameters:
       - fileManager: File manager used for discovery, ZIP output, and cleanup.
       - moduleDirectory: Canonical local module root mirrored by Android backup paths.
       - temporaryDirectory: Scratch directory that owns generated archives.
       - epubLibraryRootURL: Optional native EPUB library override for isolated hosts and tests.
     - Side effects: none; directories and archives are created only during export.
     - Failure modes: This initializer cannot fail.
     */
    internal init(
        fileManager: FileManager,
        moduleDirectory: URL,
        temporaryDirectory: URL,
        epubLibraryRootURL: URL?
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.inventoryBuilder = AndroidModuleBackupExportInventoryBuilder(
            fileManager: fileManager,
            moduleDirectory: moduleDirectory,
            epubLibraryRootURL: epubLibraryRootURL,
            reservedArchivePath: Self.manifestFileName
        )
    }

    /**
     Streams picker-selected content in exact display/selection order.

     - Parameter orderedModuleNames: Android runtime initials in picker order, or nil for all.
     - Returns: Completed file-backed Android module backup.
     - Side effects: Enumerates installed content, leases immutable EPUB generations, creates one
       temporary archive, and streams selected payload files into it. Leases are released after
       writing.
     - Throws: The same discovery, source-integrity, cancellation, ZIP, and filesystem errors.
     */
    internal func exportArchiveFile(
        orderedModuleNames: [String]?
    ) throws -> AndroidModuleBackupFileExport {
        let inventory = try inventoryBuilder.prepare(moduleNames: orderedModuleNames)
        defer { inventory.releaseEpubGenerations() }
        guard !inventory.entries.isEmpty else {
            throw AndroidModuleBackupError.noExportableModules
        }

        let entries = [
            ZipArchiveWriterFileEntry(name: Self.manifestFileName, data: try manifestData),
        ] + inventory.entries.map {
            ZipArchiveWriterFileEntry(name: $0.archivePath, pinnedFile: $0.source)
        }
        let archiveURL = temporaryDirectory.appendingPathComponent(
            "android-module-backup-export-\(UUID().uuidString).abmd.zip"
        )
        do {
            try ZipArchiveWriter.writeAndroidCompatibleDeflatedArchive(
                entries: entries,
                to: archiveURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
        return AndroidModuleBackupFileExport(
            fileName: AndroidModuleBackupService.moduleBackupFileName,
            fileURL: archiveURL,
            moduleNames: inventory.moduleNames,
            entryCount: entries.count
        )
    }

    /** Returns the same canonical all-family rows accepted by export inventory preparation. */
    internal func installedContentCatalog() throws -> [AndroidModuleBackupInstalledContent] {
        try inventoryBuilder.installedContentCatalog()
    }

    /**
     Encodes the complete Android module-backup manifest with the shared compatibility authority.

     - Returns: Kotlin-order JSON containing all four fields and a literal null category set.
     - Side effects: None; the value reads neither bundle metadata nor the filesystem.
     - Failure modes: Propagates JSON encoding failures from the shared manifest codec.
     */
    private var manifestData: Data {
        get throws {
            try AndroidBackupManifestCodec.encodeProducedBackup(
                backupType: "MODULE_BACKUP",
                contains: nil
            )
        }
    }
}
