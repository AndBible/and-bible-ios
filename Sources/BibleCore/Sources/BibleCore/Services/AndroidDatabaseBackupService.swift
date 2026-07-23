// AndroidDatabaseBackupService.swift — Android .abdb.zip import/export support

import Foundation
import SQLite3
import SwiftData
import SwordKit

/**
 Android database categories that can appear in `AndBibleDatabaseBackup.abdb.zip` archives.

 The raw values match Android's `DbType` enum when a manifest declares the category. `PROGRESS`
 is included because Android's backup writer includes `progress.sqlite3` in the archive even
 though the current manifest enum does not list it.
 */
public enum AndroidDatabaseBackupCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Android bookmark, label, bookmark-note, and StudyPad database.
    case bookmarks = "BOOKMARKS"

    /// Android workspace/window/page-manager database.
    case workspaces = "WORKSPACES"

    /// Android reading-plan database.
    case readingPlans = "READINGPLANS"

    /// Android app settings database.
    case settings = "SETTINGS"

    /// Android module repository metadata database.
    case repositories = "REPOSITORIES"

    /// Android module backup marker; module payload restore is outside database backup restore.
    case modules = "MODULES"

    /// Android EPUB backup marker; EPUB payload restore is outside database backup restore.
    case epubs = "EPUBS"

    /// Android My Documents database.
    case myDocuments = "MYDOCUMENTS"

    /// Android AI settings database.
    case aiSettings = "AI_SETTINGS"

    /// Android reading/memorization progress database.
    case progress = "PROGRESS"

    /// Stable SwiftUI identity for category selection rows.
    public var id: String { rawValue }

    /// Android database filename for categories stored as DB files in the backup archive.
    public var databaseFileName: String? {
        switch self {
        case .bookmarks:
            "bookmarks.sqlite3"
        case .workspaces:
            "workspaces.sqlite3"
        case .readingPlans:
            "readingplans.sqlite3"
        case .settings:
            "settings.sqlite3"
        case .repositories:
            "repositories.sqlite3"
        case .myDocuments:
            "mydocuments.sqlite3"
        case .aiSettings:
            "ai_settings.sqlite3"
        case .progress:
            "progress.sqlite3"
        case .modules, .epubs:
            nil
        }
    }

    /// User-visible section name matching Android's backup section labels.
    public var displayName: String {
        switch self {
        case .bookmarks:
            "Bookmarks"
        case .workspaces:
            "Workspaces"
        case .readingPlans:
            "Reading Plans"
        case .settings:
            "Settings"
        case .repositories:
            "Repositories"
        case .modules:
            "Modules"
        case .epubs:
            "EPUBs"
        case .myDocuments:
            "My Documents"
        case .aiSettings:
            "AI Settings"
        case .progress:
            "Progress"
        }
    }

    /// Highest Android Room database version this iOS build recognizes for archive validation.
    public var supportedDatabaseVersion: Int {
        switch self {
        case .bookmarks:
            12
        case .workspaces:
            RemoteSyncAndroidDatabaseContract.schemaVersion(for: .workspaces)
        case .readingPlans:
            1
        case .settings:
            1
        case .repositories:
            1
        case .myDocuments:
            RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        case .aiSettings:
            22
        case .progress:
            9
        case .modules, .epubs:
            0
        }
    }

    /// iOS remote-sync category used by the existing Android SQLite restore engines.
    public var remoteSyncCategory: RemoteSyncCategory? {
        switch self {
        case .bookmarks:
            .bookmarks
        case .workspaces:
            .workspaces
        case .readingPlans:
            .readingPlans
        case .myDocuments:
            .myDocuments
        case .progress:
            .progress
        case .settings, .repositories, .modules, .epubs, .aiSettings:
            nil
        }
    }

    /// Restore/import operations this iOS build can safely offer for the category.
    public var supportedApplyModes: [AndroidDatabaseBackupApplyMode] {
        switch self {
        case .bookmarks, .workspaces, .readingPlans, .myDocuments, .progress:
            [.restore, .import]
        case .settings, .repositories, .aiSettings:
            [.restore]
        case .modules, .epubs:
            []
        }
    }

    /// Whether the category has at least one safe apply path in this iOS build.
    public var supportsApply: Bool {
        !supportedApplyModes.isEmpty
    }

    /**
     Database-backed categories Android scans under `db/` in `.abdb.zip` archives.

     The order mirrors Android's `ALL_DB_FILENAMES` so restore/import presentation remains
     stable even when ZIP central-directory order or localized display names differ.
     */
    static var databaseBackedCases: [AndroidDatabaseBackupCategory] {
        [
            .bookmarks,
            .readingPlans,
            .workspaces,
            .repositories,
            .settings,
            .aiSettings,
            .myDocuments,
            .progress,
        ]
    }
}

/**
 Compatibility state for one Android database backup section.

 Supported sections can be restored or imported by the current iOS build. Unsupported sections are
 still exposed to the UI so the user can see that the archive contains valid data that iOS cannot
 yet map safely.
 */
public enum AndroidDatabaseBackupSectionSupport: Sendable, Equatable {
    /// The section can be restored/imported by this iOS build.
    case supported

    /// The SQLite database version is newer than the highest version this iOS build recognizes.
    case unsupportedVersion(version: Int, supported: Int)

    /// The Android category has no iOS data mapper yet.
    case unsupportedCategory(String)

    /// Whether this support state permits restore/import.
    public var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }

    /// User-facing explanation for unsupported states.
    public var explanation: String? {
        switch self {
        case .supported:
            nil
        case .unsupportedVersion(let version, let supported):
            "Requires database version \(version); this app supports up to \(supported)."
        case .unsupportedCategory(let message):
            message
        }
    }
}

/**
 One validated database section extracted from an Android backup archive.

 The database file URL points at a temporary extracted SQLite file owned by
 `AndroidDatabaseBackupArchive.temporaryDirectory`; callers should keep the archive value alive
 until all selected restore/import operations have completed.
 */
public struct AndroidDatabaseBackupSection: Identifiable, Sendable, Equatable {
    /// Stable category identity used for selection and dispatch.
    public let category: AndroidDatabaseBackupCategory

    /// Android database filename under the archive's `db/` directory.
    public let fileName: String

    /// Temporary extracted SQLite database URL.
    public let databaseFileURL: URL

    /// SQLite `PRAGMA user_version` read from the extracted database.
    public let databaseVersion: Int

    /// Whether the archive manifest declared this category.
    public let declaredInManifest: Bool

    /// Restore/import compatibility for this iOS build.
    public let support: AndroidDatabaseBackupSectionSupport

    /// Stable SwiftUI identity for section rows.
    public var id: AndroidDatabaseBackupCategory { category }

    /// Whether this section was backed by an extracted SQLite database file.
    public var hasDatabaseFile: Bool { !fileName.isEmpty }

    /**
     Creates one extracted Android database backup section.

     - Parameters:
       - category: Logical Android category represented by the database.
       - fileName: Android database filename under `db/`.
       - databaseFileURL: Temporary extracted SQLite database URL.
       - databaseVersion: SQLite `user_version`.
       - declaredInManifest: Whether `AndBibleBackupManifest.json` listed the category.
       - support: Restore/import compatibility for the current iOS build.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        category: AndroidDatabaseBackupCategory,
        fileName: String,
        databaseFileURL: URL,
        databaseVersion: Int,
        declaredInManifest: Bool,
        support: AndroidDatabaseBackupSectionSupport
    ) {
        self.category = category
        self.fileName = fileName
        self.databaseFileURL = databaseFileURL
        self.databaseVersion = databaseVersion
        self.declaredInManifest = declaredInManifest
        self.support = support
    }
}

/**
 Manifest payload read from `AndBibleBackupManifest.json`.

 Android currently writes `backupType = DB_BACKUP`, `manifestVersion = 1`, and an optional
 `contains` set. Older or hand-carried Android database backups may not contain this file, so iOS
 treats the manifest as optional metadata while using valid `db/` SQLite entries as the authoritative
 restore section source.
 */
public struct AndroidDatabaseBackupManifest: Sendable, Equatable {
    /// Android backup type string, expected to be `DB_BACKUP`.
    public let backupType: String

    /// Optional category set declared by Android's manifest.
    public let contains: Set<AndroidDatabaseBackupCategory>

    /// Manifest schema version.
    public let manifestVersion: Int

    /// Android application version number that created the backup.
    public let andBibleVersion: Int?

    /**
     Creates one decoded Android database backup manifest.

     - Parameters:
       - backupType: Android backup type string.
       - contains: Optional category set declared by Android.
       - manifestVersion: Manifest schema version.
       - andBibleVersion: Android application version number, when present.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        backupType: String,
        contains: Set<AndroidDatabaseBackupCategory>,
        manifestVersion: Int,
        andBibleVersion: Int?
    ) {
        self.backupType = backupType
        self.contains = contains
        self.manifestVersion = manifestVersion
        self.andBibleVersion = andBibleVersion
    }
}

/**
 Loaded Android database backup archive with staged SQLite database files.

 The archive owns a temporary directory. Call `AndroidDatabaseBackupService.cleanup(_:)` after the
 UI is dismissed or after restore/import completes.
 */
public struct AndroidDatabaseBackupArchive: Identifiable, Sendable {
    /// Stable identity for SwiftUI sheet presentation.
    public let id: UUID

    /// Decoded Android backup manifest metadata when Android supplied usable DB metadata.
    public let manifest: AndroidDatabaseBackupManifest?

    /// Valid database sections extracted from the archive.
    public let sections: [AndroidDatabaseBackupSection]

    /// Temporary root directory containing staged SQLite files.
    public let temporaryDirectory: URL

    /**
     Creates one loaded Android backup archive.

     - Parameters:
       - id: Stable identity for UI presentation.
       - manifest: Decoded Android backup manifest metadata, when present and usable.
       - sections: Valid database sections extracted from the archive.
       - temporaryDirectory: Temporary root directory containing staged SQLite files.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID = UUID(),
        manifest: AndroidDatabaseBackupManifest?,
        sections: [AndroidDatabaseBackupSection],
        temporaryDirectory: URL
    ) {
        self.id = id
        self.manifest = manifest
        self.sections = sections
        self.temporaryDirectory = temporaryDirectory
    }
}

/**
 Exported Android database backup archive.

 The archive uses Android's manual database backup shape: `AndBibleBackupManifest.json` at the
 archive root and one SQLite database per supported category beneath `db/`.
 */
public struct AndroidDatabaseBackupExport: Sendable, Equatable {
    /// Android-compatible filename used by the share sheet.
    public let fileName: String

    /// Raw `.abdb.zip` archive bytes.
    public let data: Data

    /// Categories materialized into SQLite entries under `db/`.
    public let categories: [AndroidDatabaseBackupCategory]

    /// Number of ZIP file entries, including the manifest.
    public let entryCount: Int

    /**
     Creates one Android database backup export summary.

     - Parameters:
       - fileName: Android-compatible filename used by the share sheet.
       - data: Raw `.abdb.zip` archive bytes.
       - categories: Categories materialized into SQLite entries under `db/`.
       - entryCount: Number of ZIP file entries, including the manifest.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        fileName: String,
        data: Data,
        categories: [AndroidDatabaseBackupCategory],
        entryCount: Int
    ) {
        self.fileName = fileName
        self.data = data
        self.categories = categories
        self.entryCount = entryCount
    }
}

/**
 File-backed Android database backup export.

 This result is the production share-sheet path for manual backup export. It points at a complete
 `.abdb.zip` file so callers can share or move the archive without keeping the whole ZIP in memory.
 */
public struct AndroidDatabaseBackupFileExport: Sendable, Equatable {
    /// Android-compatible filename used by the share sheet.
    public let fileName: String

    /// Complete `.abdb.zip` archive file. The caller owns cleanup after sharing or moving it.
    public let fileURL: URL

    /// Categories materialized into SQLite entries under `db/`.
    public let categories: [AndroidDatabaseBackupCategory]

    /// Number of ZIP file entries, including the manifest.
    public let entryCount: Int

    /**
     Creates one file-backed Android database backup export summary.

     - Parameters:
       - fileName: Android-compatible filename used by the share sheet.
       - fileURL: Complete `.abdb.zip` archive file.
       - categories: Categories materialized into SQLite entries under `db/`.
       - entryCount: Number of ZIP file entries, including the manifest.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        fileName: String,
        fileURL: URL,
        categories: [AndroidDatabaseBackupCategory],
        entryCount: Int
    ) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.categories = categories
        self.entryCount = entryCount
    }
}

/**
 User-selected operation for one Android backup section.
 */
public enum AndroidDatabaseBackupApplyMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Replace local category data with the selected Android database section.
    case restore

    /// Add backup rows that do not already exist locally without overwriting existing rows.
    case `import`

    /// Stable identity for SwiftUI segmented controls.
    public var id: String { rawValue }

    /// User-visible label.
    public var displayName: String {
        switch self {
        case .restore:
            "Restore"
        case .import:
            "Import"
        }
    }
}

/**
 One selected section and operation mode from the Android backup UI.
 */
public struct AndroidDatabaseBackupSelection: Sendable, Equatable {
    /// Selected Android backup category.
    public let category: AndroidDatabaseBackupCategory

    /// Restore/import operation requested for the category.
    public let mode: AndroidDatabaseBackupApplyMode

    /**
     Creates one restore/import selection.

     - Parameters:
       - category: Selected Android backup category.
       - mode: Restore/import operation requested for the category.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: AndroidDatabaseBackupCategory, mode: AndroidDatabaseBackupApplyMode) {
        self.category = category
        self.mode = mode
    }
}

/**
 Summary for one section applied from an Android database backup archive.
 */
public struct AndroidDatabaseBackupAppliedSectionReport: Sendable, Equatable {
    /// Applied Android backup category.
    public let category: AndroidDatabaseBackupCategory

    /// Operation mode used for the category.
    public let mode: AndroidDatabaseBackupApplyMode

    /// Human-readable row summary for status UI and tests.
    public let summary: String

    /**
     Creates one applied-section report.

     - Parameters:
       - category: Applied Android backup category.
       - mode: Operation mode used for the category.
       - summary: Human-readable row summary for status UI and tests.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: AndroidDatabaseBackupCategory, mode: AndroidDatabaseBackupApplyMode, summary: String) {
        self.category = category
        self.mode = mode
        self.summary = summary
    }
}

/**
 Summary for a completed Android database backup restore/import batch.
 */
public struct AndroidDatabaseBackupApplyReport: Sendable, Equatable {
    /// Per-section reports in the order requested by the user.
    public let sections: [AndroidDatabaseBackupAppliedSectionReport]

    /**
     Creates a completed batch report.

     - Parameter sections: Per-section reports in the order requested by the user.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(sections: [AndroidDatabaseBackupAppliedSectionReport]) {
        self.sections = sections
    }
}

/**
 Errors raised while loading or applying Android database backup archives.
 */
public enum AndroidDatabaseBackupError: LocalizedError, Equatable {
    /// The archive could not be parsed as ZIP.
    case invalidArchive(String)

    /// The required Android manifest file was missing.
    case missingManifest

    /// The Android manifest could not be decoded.
    case invalidManifest

    /// The manifest described a backup type other than `DB_BACKUP`.
    case unsupportedBackupType(String)

    /// The manifest version is newer than this iOS build understands.
    case unsupportedManifestVersion(Int)

    /// The archive contained no recognizable Android database backup sections.
    case noValidDatabaseSections

    /// One expected SQLite database could not be opened or did not have a SQLite header.
    case invalidSQLiteDatabase(String)

    /// The caller requested no sections.
    case emptySelection

    /// The requested category was not present in the loaded archive.
    case missingSelectedSection(AndroidDatabaseBackupCategory)

    /// The requested category is present but cannot be mapped by this iOS build.
    case unsupportedSelectedSection(AndroidDatabaseBackupCategory, String)

    /// User-visible error description.
    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            "Invalid Android backup archive: \(message)"
        case .missingManifest:
            "The Android backup manifest is missing."
        case .invalidManifest:
            "The Android backup manifest could not be read."
        case .unsupportedBackupType(let type):
            "This archive is \(type), not an Android database backup."
        case .unsupportedManifestVersion(let version):
            "This Android backup manifest version (\(version)) is newer than iOS supports."
        case .noValidDatabaseSections:
            "No Android database backup sections were found."
        case .invalidSQLiteDatabase(let fileName):
            "\(fileName) is not a valid Android SQLite database."
        case .emptySelection:
            "Choose at least one Android backup section."
        case .missingSelectedSection(let category):
            "\(category.displayName) was not found in this backup."
        case .unsupportedSelectedSection(let category, let reason):
            "\(category.displayName) cannot be restored: \(reason)"
        }
    }
}

/**
 Loads Android `.abdb.zip` archives and applies selected sections to iOS SwiftData.

 Android's manual backup restore offers section selection and a per-section Restore/Import choice.
 This service preserves those semantics for iOS:
 - `Restore` replaces local category data from the selected Android SQLite database
 - `Import` builds a merged Android-shaped snapshot that keeps local rows first and adds backup
   rows only when their Android uniqueness keys are absent
 - after each selected section is applied, Android-aligned remote-sync bookkeeping for that
   category is disabled and cleared so manual restore/import does not masquerade as synchronized
   remote state
 */
public final class AndroidDatabaseBackupService {
    /// Android file suffix for manual database backups.
    public static let databaseBackupSuffix = ".abdb.zip"

    /// Android's canonical manual database backup filename.
    public static let databaseBackupFileName = "AndBibleDatabaseBackup.abdb.zip"

    /// Manifest filename used by Android database and module backup archives.
    private static let manifestFileName = AndroidBackupManifestCodec.fileName

    /// Semantic category databases iOS can materialize directly from native state.
    private static let semanticExportableDatabaseCategories: [AndroidDatabaseBackupCategory] = [
        .bookmarks,
        .readingPlans,
        .workspaces,
        .repositories,
        .settings,
        .myDocuments,
        .progress,
    ]

    /// Largest Android backup manifest accepted for in-memory JSON decoding.
    private static let maximumManifestByteCount = 1024 * 1024

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let bookmarkRestoreService: RemoteSyncBookmarkRestoreService
    private let bookmarkSnapshotService: RemoteSyncBookmarkSnapshotService
    private let readingPlanRestoreService: RemoteSyncReadingPlanRestoreService
    private let readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService
    private let workspaceRestoreService: RemoteSyncWorkspaceRestoreService
    private let myDocumentRestoreService: RemoteSyncMyDocumentRestoreService
    private let myDocumentSnapshotService: RemoteSyncMyDocumentSnapshotService
    private let repositorySourceManager: RepositorySourceManager
    private let preservedDatabaseStore: AndroidDatabaseBackupPreservedDatabaseStore

    /**
     Creates an Android database backup service.

     - Parameters:
       - fileManager: File manager used for temporary extraction and cleanup.
       - temporaryDirectory: Root scratch directory for extracted archive contents.
       - bookmarkRestoreService: Bookmark restore engine for Android `bookmarks.sqlite3`.
       - bookmarkSnapshotService: Bookmark snapshot engine used for non-destructive import merges.
       - readingPlanRestoreService: Reading-plan restore engine for Android `readingplans.sqlite3`.
       - readingPlanSnapshotService: Reading-plan snapshot engine used for import merges.
       - workspaceRestoreService: Workspace restore engine for Android `workspaces.sqlite3`.
       - myDocumentRestoreService: My Documents restore engine for Android `mydocuments.sqlite3`.
       - myDocumentSnapshotService: My Documents snapshot engine used for import merges.
       - repositorySourceManager: Repository source manager used for Android `repositories.sqlite3`.
       - preservedDatabaseStore: Store used to preserve Android-owned databases without native iOS
         semantic models, currently Android `ai_settings.sqlite3`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        bookmarkRestoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        bookmarkSnapshotService: RemoteSyncBookmarkSnapshotService = RemoteSyncBookmarkSnapshotService(),
        readingPlanRestoreService: RemoteSyncReadingPlanRestoreService = RemoteSyncReadingPlanRestoreService(),
        readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService = RemoteSyncReadingPlanSnapshotService(),
        workspaceRestoreService: RemoteSyncWorkspaceRestoreService = RemoteSyncWorkspaceRestoreService(),
        myDocumentRestoreService: RemoteSyncMyDocumentRestoreService = RemoteSyncMyDocumentRestoreService(),
        myDocumentSnapshotService: RemoteSyncMyDocumentSnapshotService = RemoteSyncMyDocumentSnapshotService(),
        repositorySourceManager: RepositorySourceManager = RepositorySourceManager(),
        preservedDatabaseStore: AndroidDatabaseBackupPreservedDatabaseStore = AndroidDatabaseBackupPreservedDatabaseStore()
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.bookmarkRestoreService = bookmarkRestoreService
        self.bookmarkSnapshotService = bookmarkSnapshotService
        self.readingPlanRestoreService = readingPlanRestoreService
        self.readingPlanSnapshotService = readingPlanSnapshotService
        self.workspaceRestoreService = workspaceRestoreService
        self.myDocumentRestoreService = myDocumentRestoreService
        self.myDocumentSnapshotService = myDocumentSnapshotService
        self.repositorySourceManager = repositorySourceManager
        self.preservedDatabaseStore = preservedDatabaseStore
    }

    /**
     Exports local data as Android's `.abdb.zip` manual database backup format.

     - Parameters:
       - modelContext: SwiftData context that owns the local category rows.
       - settingsStore: Local-only settings store that backs Android fidelity metadata.
     - Returns: Android-compatible database backup archive bytes and exported category summary.
     - Side effects:
       - reads supported local categories from SwiftData and fidelity settings
       - writes temporary Android-shaped SQLite databases beneath the configured temporary directory
       - removes the temporary SQLite databases after the ZIP archive is materialized
     - Failure modes:
       - rethrows category snapshot, SQLite, JSON manifest, file read, and ZIP writer failures
       - unsupported categories are intentionally omitted rather than emitted as empty databases
     */
    public func exportArchive(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupExport {
        let fileExport = try exportArchiveFile(modelContext: modelContext, settingsStore: settingsStore)
        defer { try? fileManager.removeItem(at: fileExport.fileURL) }
        let archiveData = try Data(contentsOf: fileExport.fileURL)
        return AndroidDatabaseBackupExport(
            fileName: fileExport.fileName,
            data: archiveData,
            categories: fileExport.categories,
            entryCount: fileExport.entryCount
        )
    }

    /**
     Exports local data as an Android `.abdb.zip` file without buffering the whole archive.

     - Parameters:
       - modelContext: SwiftData context that owns the local category rows.
       - settingsStore: Local-only settings store that backs Android fidelity metadata.
     - Returns: File-backed Android-compatible backup archive and exported category summary.
     - Side effects:
       - reads supported local categories from SwiftData and fidelity settings
       - writes temporary Android-shaped SQLite databases beneath the configured temporary directory
       - writes a complete `.abdb.zip` archive file beneath the configured temporary directory
       - removes intermediate SQLite databases after the ZIP archive is materialized
     - Failure modes:
       - rethrows category snapshot, SQLite, JSON manifest, file read/write, and ZIP writer failures
       - unsupported categories are intentionally omitted rather than emitted as empty databases
     - Note: The returned archive file remains on disk for the caller to share or move; the caller owns
       cleanup of `fileURL`.
     */
    public func exportArchiveFile(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupFileExport {
        let exportCategories = exportableDatabaseCategories()
        let manifestData = try AndroidBackupManifestCodec.encode(
            backupType: "DB_BACKUP",
            contains: exportCategories.map(\.rawValue),
            andBibleVersion: AndroidBackupManifestCodec.producerVersion()
        )
        var entries: [ZipArchiveWriterFileEntry] = [
            ZipArchiveWriterFileEntry(name: Self.manifestFileName, data: manifestData),
        ]
        var temporaryDatabaseURLs: [URL] = []
        defer {
            for databaseURL in temporaryDatabaseURLs {
                try? fileManager.removeItem(at: databaseURL)
            }
        }

        for category in exportCategories {
            guard let databaseFileName = category.databaseFileName else {
                continue
            }
            let databaseURL = try buildExportDatabase(
                for: category,
                modelContext: modelContext,
                settingsStore: settingsStore,
                databaseFileName: databaseFileName
            )
            temporaryDatabaseURLs.append(databaseURL)
            entries.append(
                ZipArchiveWriterFileEntry(
                    name: "db/\(databaseFileName)",
                    fileURL: databaseURL
                )
            )
        }

        let archiveURL = temporaryURL(prefix: "android-database-backup-export-", suffix: ".abdb.zip")
        do {
            try ZipArchiveWriter.writeStoredArchive(entries: entries, to: archiveURL, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }

        return AndroidDatabaseBackupFileExport(
            fileName: Self.databaseBackupFileName,
            fileURL: archiveURL,
            categories: exportCategories,
            entryCount: entries.count
        )
    }

    private func exportableDatabaseCategories() -> [AndroidDatabaseBackupCategory] {
        var categories = Self.semanticExportableDatabaseCategories
        guard preservedDatabaseStore.hasDatabase(for: .aiSettings),
              let insertionIndex = categories.firstIndex(of: .myDocuments) else {
            return categories
        }
        categories.insert(.aiSettings, at: insertionIndex)
        return categories
    }

    private func buildExportDatabase(
        for category: AndroidDatabaseBackupCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        databaseFileName: String
    ) throws -> URL {
        switch category {
        case .bookmarks, .readingPlans, .workspaces, .myDocuments:
            guard let remoteSyncCategory = category.remoteSyncCategory else {
                throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                    category,
                    "iOS does not yet have an export mapper for Android \(category.displayName) data."
                )
            }
            return try RemoteSyncInitialBackupUploadService.buildAndroidDatabaseBackupDatabase(
                for: remoteSyncCategory,
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: category.supportedDatabaseVersion,
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory
            )
        case .settings:
            let databaseURL = temporaryURL(prefix: "android-database-backup-settings-", suffix: "-\(databaseFileName)")
            try AndroidDatabaseBackupSettingsMapper.writeDatabase(at: databaseURL, settingsStore: settingsStore)
            return databaseURL
        case .repositories:
            let databaseURL = temporaryURL(prefix: "android-database-backup-repositories-", suffix: "-\(databaseFileName)")
            try AndroidDatabaseBackupRepositoryMapper.writeDatabase(
                at: databaseURL,
                repositorySourceManager: repositorySourceManager
            )
            return databaseURL
        case .progress:
            let databaseURL = temporaryURL(prefix: "android-database-backup-progress-", suffix: "-\(databaseFileName)")
            try AndroidDatabaseBackupProgressMapper.writeDatabase(at: databaseURL, settingsStore: settingsStore)
            return databaseURL
        case .aiSettings:
            let databaseURL = temporaryURL(prefix: "android-database-backup-ai-settings-", suffix: "-\(databaseFileName)")
            guard try preservedDatabaseStore.copyDatabase(for: .aiSettings, to: databaseURL) != nil else {
                throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                    category,
                    "No preserved Android \(category.displayName) database is available to export."
                )
            }
            return databaseURL
        case .modules, .epubs:
            throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                category,
                "iOS does not yet have an export mapper for Android \(category.displayName) data."
            )
        }
    }

    /**
     Loads and validates an Android `.abdb.zip` database backup archive.

     - Parameter data: Raw backup archive bytes selected by the user.
     - Returns: Loaded archive with extracted SQLite database sections.
     - Side effects:
       - creates one temporary directory
       - writes recognized Android database entries into that directory
       - opens each extracted SQLite file read-only to verify the header and `user_version`
     - Failure modes:
       - throws `AndroidDatabaseBackupError` for invalid SQLite files or archives without
         recognizable database sections
       - maps ZIP parser failures into user-facing archive reasons before surfacing them through
         Settings status text
       - throws file-system errors when temporary staging cannot be created
     */
    public func loadArchive(from data: Data) throws -> AndroidDatabaseBackupArchive {
        let entries: [ZipArchiveEntry]
        do {
            entries = try ZipArchiveReader.entries(in: data)
        } catch let error as ZipArchiveReaderError {
            throw AndroidDatabaseBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        } catch {
            throw AndroidDatabaseBackupError.invalidArchive(error.localizedDescription)
        }

        let entriesByName = try Self.entriesByUniqueName(entries)
        let loadedManifest = loadDatabaseManifest(from: entriesByName[Self.manifestFileName])
        let manifest = loadedManifest.manifest

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "android-db-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var sections: [AndroidDatabaseBackupSection] = []
        do {
            for category in AndroidDatabaseBackupCategory.databaseBackedCases {
                guard let fileName = category.databaseFileName,
                      let databaseData = entriesByName["db/\(fileName)"] else {
                    continue
                }

                guard Self.hasSQLiteHeader(databaseData) else {
                    throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
                }

                let databaseURL = stagingDirectory.appendingPathComponent(fileName)
                try databaseData.write(to: databaseURL, options: .atomic)
                let databaseVersion = try sqliteUserVersion(at: databaseURL, fileName: fileName)
                let support = supportState(for: category, databaseVersion: databaseVersion)
                sections.append(
                    AndroidDatabaseBackupSection(
                        category: category,
                        fileName: fileName,
                        databaseFileURL: databaseURL,
                        databaseVersion: databaseVersion,
                        declaredInManifest: loadedManifest.declaredCategories.contains(category),
                        support: support
                    )
                )
            }

            guard !sections.isEmpty else {
                throw AndroidDatabaseBackupError.noValidDatabaseSections
            }
            return AndroidDatabaseBackupArchive(
                manifest: manifest,
                sections: Self.sectionsInAndroidRestoreOrder(sections),
                temporaryDirectory: stagingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    /**
     Loads and validates an Android `.abdb.zip` database backup archive from a file URL.

     This is the production restore path. It mirrors Android's file-backed restore semantics by
     reading ZIP metadata from the selected archive and streaming selected database entries into a
     temporary staging directory instead of materializing the whole ZIP or every entry in memory.

     - Parameter archiveURL: File URL for a user-selected Android database backup archive.
     - Returns: Loaded archive with extracted SQLite database sections.
     - Side effects:
       - creates one temporary directory
       - streams recognized Android database entries into that directory
       - opens each extracted SQLite file read-only to verify the header and `user_version`
     - Failure modes:
       - throws `AndroidDatabaseBackupError` for invalid SQLite files, duplicate entries, or
         archives without recognizable database sections
       - maps ZIP parser failures into user-facing archive reasons before surfacing them through
         Settings status text
       - throws file-system errors when temporary staging cannot be created or written
     */
    public func loadArchive(fromArchiveAt archiveURL: URL) throws -> AndroidDatabaseBackupArchive {
        let entries: [ZipArchiveFileEntry]
        do {
            entries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        } catch let error as ZipArchiveReaderError {
            throw AndroidDatabaseBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
        } catch {
            throw AndroidDatabaseBackupError.invalidArchive(error.localizedDescription)
        }

        let entriesByName = try Self.fileEntriesByUniqueName(entries)
        let manifestData: Data?
        if let manifestEntry = entriesByName[Self.manifestFileName] {
            manifestData = try? ZipArchiveReader.data(
                for: manifestEntry,
                inArchiveAt: archiveURL,
                maximumByteCount: Self.maximumManifestByteCount,
                fileManager: fileManager
            )
        } else {
            manifestData = nil
        }
        let loadedManifest = loadDatabaseManifest(from: manifestData)
        let manifest = loadedManifest.manifest

        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "android-db-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        var sections: [AndroidDatabaseBackupSection] = []
        do {
            for category in AndroidDatabaseBackupCategory.databaseBackedCases {
                guard let fileName = category.databaseFileName,
                      let databaseEntry = entriesByName["db/\(fileName)"] else {
                    continue
                }

                let databaseURL = stagingDirectory.appendingPathComponent(fileName)
                do {
                    try ZipArchiveReader.extract(
                        databaseEntry,
                        fromArchiveAt: archiveURL,
                        to: databaseURL,
                        fileManager: fileManager
                    )
                } catch let error as ZipArchiveReaderError {
                    throw AndroidDatabaseBackupError.invalidArchive(Self.archiveErrorMessage(for: error))
                }
                guard Self.hasSQLiteHeader(at: databaseURL) else {
                    throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
                }

                let databaseVersion = try sqliteUserVersion(at: databaseURL, fileName: fileName)
                let support = supportState(for: category, databaseVersion: databaseVersion)
                sections.append(
                    AndroidDatabaseBackupSection(
                        category: category,
                        fileName: fileName,
                        databaseFileURL: databaseURL,
                        databaseVersion: databaseVersion,
                        declaredInManifest: loadedManifest.declaredCategories.contains(category),
                        support: support
                    )
                )
            }

            guard !sections.isEmpty else {
                throw AndroidDatabaseBackupError.noValidDatabaseSections
            }
            return AndroidDatabaseBackupArchive(
                manifest: manifest,
                sections: Self.sectionsInAndroidRestoreOrder(sections),
                temporaryDirectory: stagingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    /**
     Applies selected Android backup sections to local SwiftData.

     - Parameters:
       - archive: Previously loaded Android backup archive.
       - selections: User-selected category/mode pairs.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Local-only settings store used by restore engines and sync-state reset.
     - Returns: Per-section apply summaries.
     - Side effects:
       - mutates category data in `modelContext`
       - writes or clears category-specific local-only fidelity state through `settingsStore`
       - disables and clears Android-aligned remote-sync bookkeeping for every applied category
     - Failure modes:
       - throws when a selected section is missing, unsupported, malformed, or cannot be saved
     */
    public func apply(
        archive: AndroidDatabaseBackupArchive,
        selections: [AndroidDatabaseBackupSelection],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupApplyReport {
        guard !selections.isEmpty else {
            throw AndroidDatabaseBackupError.emptySelection
        }

        let sectionsByCategory = Dictionary(uniqueKeysWithValues: archive.sections.map { ($0.category, $0) })
        var reports: [AndroidDatabaseBackupAppliedSectionReport] = []
        for selection in selections {
            guard let section = sectionsByCategory[selection.category] else {
                throw AndroidDatabaseBackupError.missingSelectedSection(selection.category)
            }
            guard section.support.isSupported else {
                throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                    selection.category,
                    section.support.explanation ?? "Unsupported by this iOS build."
                )
            }
            guard section.category.supportedApplyModes.contains(selection.mode) else {
                throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                    selection.category,
                    unsupportedApplyModeReason(for: selection.category, mode: selection.mode)
                )
            }

            let summary = try applySupportedSection(
                section,
                mode: selection.mode,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            if let category = section.category.remoteSyncCategory {
                resetManualBackupSyncState(for: category, settingsStore: settingsStore)
            }
            reports.append(
                AndroidDatabaseBackupAppliedSectionReport(
                    category: section.category,
                    mode: selection.mode,
                    summary: summary
                )
            )
        }

        return AndroidDatabaseBackupApplyReport(sections: reports)
    }

    /**
     Removes temporary files owned by a loaded archive.

     - Parameter archive: Loaded archive whose temporary directory should be deleted.
     - Side effects: deletes the archive staging directory when present.
     - Failure modes: Delete errors are swallowed because cleanup is best effort.
     */
    public func cleanup(_ archive: AndroidDatabaseBackupArchive) {
        try? fileManager.removeItem(at: archive.temporaryDirectory)
    }

    /**
     Manifest metadata plus the categories actually declared by a manifest file.

     Missing or unusable manifests are valid for Android database restore because sections are
     discovered from filenames under `db/`. This wrapper keeps optional public manifest metadata
     and per-section declaration state separate.
     */
    private struct LoadedDatabaseManifest {
        /// Decoded manifest metadata exposed on `AndroidDatabaseBackupArchive`, when usable.
        let manifest: AndroidDatabaseBackupManifest?

        /// Categories that were listed in an actual `AndBibleBackupManifest.json` file.
        let declaredCategories: Set<AndroidDatabaseBackupCategory>
    }

    /**
     Loads optional Android DB manifest metadata.

     Android database restore scans database filenames instead of requiring the manifest. A present
     manifest is preserved only when it decodes as current DB metadata. Malformed, non-DB, or future
     manifest payloads are ignored so they cannot override valid database section discovery.

     - Parameter data: Raw `AndBibleBackupManifest.json` bytes, or `nil` when the archive omits it.
     - Returns: Loaded manifest metadata and actual declared category set.
     - Side effects: none.
     - Failure modes: This helper does not throw; bad manifest metadata is advisory and ignored.
     */
    private func loadDatabaseManifest(from data: Data?) -> LoadedDatabaseManifest {
        guard let data else {
            return LoadedDatabaseManifest(manifest: nil, declaredCategories: [])
        }

        guard let manifest = try? decodeManifest(from: data),
              manifest.backupType == "DB_BACKUP",
              manifest.manifestVersion <= 1 else {
            return LoadedDatabaseManifest(manifest: nil, declaredCategories: [])
        }
        return LoadedDatabaseManifest(manifest: manifest, declaredCategories: manifest.contains)
    }

    /**
     Orders loaded database sections the same way Android scans `ALL_DB_FILENAMES`.

     - Parameter sections: Valid database-backed sections discovered in the archive.
     - Returns: Sections sorted by Android restore order, with a deterministic fallback for any
       future category not represented in the current order table.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sectionsInAndroidRestoreOrder(
        _ sections: [AndroidDatabaseBackupSection]
    ) -> [AndroidDatabaseBackupSection] {
        let orderByCategory = Dictionary(
            uniqueKeysWithValues: AndroidDatabaseBackupCategory.databaseBackedCases.enumerated().map { index, category in
                (category, index)
            }
        )
        return sections.sorted { lhs, rhs in
            let lhsOrder = orderByCategory[lhs.category] ?? Int.max
            let rhsOrder = orderByCategory[rhs.category] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }

    /**
     Decodes Android's JSON backup manifest into the normalized manifest model.

     - Parameter data: Raw `AndBibleBackupManifest.json` bytes.
     - Returns: Manifest with missing optional fields normalized to Android-compatible defaults.
     - Side effects: none.
     - Failure modes: throws `AndroidDatabaseBackupError.invalidManifest` when JSON does not match
       Android's manifest shape.
     */
    private func decodeManifest(from data: Data) throws -> AndroidDatabaseBackupManifest {
        guard let dto = try? AndroidBackupManifestCodec.decode(data) else {
            throw AndroidDatabaseBackupError.invalidManifest
        }
        return AndroidDatabaseBackupManifest(
            backupType: dto.backupType,
            contains: Set(
                (dto.contains ?? []).compactMap(AndroidDatabaseBackupCategory.init(rawValue:))
            ),
            manifestVersion: dto.manifestVersion ?? 1,
            andBibleVersion: dto.andBibleVersion
        )
    }

    /**
     Builds a deterministic ZIP entry lookup for Android backup archives.

     ZIP archives may legally contain multiple file members with the same path. Android database
     backup restore treats paths such as `AndBibleBackupManifest.json` and `db/bookmarks.sqlite3`
     as authoritative inputs, so duplicate names would make the selected manifest or SQLite payload
     ambiguous. Rejecting duplicates before validation keeps restore/import fail-closed instead of
     letting a later central-directory entry replace an earlier one.

     - Parameter entries: Non-directory entries extracted from `ZipArchiveReader` in central-directory order.
     - Returns: Entry payloads keyed by their ZIP path.
     - Side effects: none.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidArchive` when any entry path appears
       more than once.
     */
    private static func entriesByUniqueName(_ entries: [ZipArchiveEntry]) throws -> [String: Data] {
        var entriesByName: [String: Data] = [:]
        for entry in entries {
            guard entriesByName[entry.name] == nil else {
                throw AndroidDatabaseBackupError.invalidArchive(
                    "ZIP archive contains duplicate entry \(entry.name)."
                )
            }
            entriesByName[entry.name] = entry.data
        }
        return entriesByName
    }

    /**
     Builds a deterministic ZIP file-entry lookup for file-backed Android backup archives.

     This mirrors `entriesByUniqueName(_:)` without materializing payload bytes. Duplicate archive
     paths remain invalid because Android restore treats manifest and `db/` paths as authoritative
     inputs.

     - Parameter entries: Non-directory file-backed entries in central-directory order.
     - Returns: Entry descriptors keyed by ZIP path.
     - Side effects: none.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidArchive` when any entry path appears
       more than once.
     */
    private static func fileEntriesByUniqueName(_ entries: [ZipArchiveFileEntry]) throws -> [String: ZipArchiveFileEntry] {
        var entriesByName: [String: ZipArchiveFileEntry] = [:]
        for entry in entries {
            guard entriesByName[entry.name] == nil else {
                throw AndroidDatabaseBackupError.invalidArchive(
                    "ZIP archive contains duplicate entry \(entry.name)."
                )
            }
            entriesByName[entry.name] = entry
        }
        return entriesByName
    }

    /**
     Converts low-level ZIP parser errors into Settings-safe archive failure messages.

     `ZipArchiveReaderError` is useful for tests and parser internals but its enum case names are
     not suitable for user-facing import status text. This mapper preserves concrete malformed
     archive reasons while replacing enum-only failures with concise explanations.

     - Parameter error: ZIP parser error raised while loading an Android backup file.
     - Returns: User-facing archive error detail used by `AndroidDatabaseBackupError.invalidArchive`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func archiveErrorMessage(for error: ZipArchiveReaderError) -> String {
        switch error {
        case .missingCentralDirectory:
            return "The file is not a ZIP archive or its central directory is missing."
        case .invalidArchive(let reason):
            return reason
        case .unsupportedCompressionMethod(let method):
            return "ZIP entry uses unsupported compression method \(method)."
        case .decompressionFailed:
            return "A compressed ZIP entry could not be decompressed."
        }
    }

    /**
     Determines whether this iOS build can safely apply one extracted Android database section.

     - Parameters:
       - category: Android backup category represented by the database.
       - databaseVersion: SQLite `user_version` read from the extracted file.
     - Returns: Supported state, unsupported-version state, or unsupported-category state.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func supportState(
        for category: AndroidDatabaseBackupCategory,
        databaseVersion: Int
    ) -> AndroidDatabaseBackupSectionSupport {
        guard category.supportsApply else {
            return .unsupportedCategory("iOS does not yet have a safe mapper for Android \(category.displayName) data.")
        }
        let isUnsupportedWorkspaceGeneration = category == .workspaces
            && !RemoteSyncWorkspaceDatabaseMigrator.supportsSourceVersion(databaseVersion)
        if databaseVersion > category.supportedDatabaseVersion
            || isUnsupportedWorkspaceGeneration {
            return .unsupportedVersion(version: databaseVersion, supported: category.supportedDatabaseVersion)
        }
        return .supported
    }

    private func unsupportedApplyModeReason(
        for category: AndroidDatabaseBackupCategory,
        mode: AndroidDatabaseBackupApplyMode
    ) -> String {
        if mode == .import, category.supportedApplyModes == [.restore] {
            return "\(category.displayName) can only be restored because Android treats \(category.databaseFileName ?? "this database") as a restore-only database."
        }
        return "\(mode.displayName) is not supported for Android \(category.displayName) data."
    }

    /**
     Reads SQLite `PRAGMA user_version` from an extracted Android database file.

     - Parameters:
       - url: Extracted SQLite database URL.
       - fileName: Android database filename used in thrown errors.
     - Returns: Integer user-version marker.
     - Side effects: opens the database read-only and finalizes its statement.
     - Failure modes: throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` if SQLite cannot
       open or read the version pragma.
     */
    private func sqliteUserVersion(at url: URL, fileName: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    /**
     Checks the SQLite file magic before writing archive bytes to a staging path.

     - Parameter data: Raw database entry bytes from the ZIP archive.
     - Returns: `true` when the entry starts with SQLite's canonical header.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func hasSQLiteHeader(_ data: Data) -> Bool {
        data.count >= 16 && Data(data.prefix(16)) == Data("SQLite format 3\u{0}".utf8)
    }

    /**
     Checks the SQLite file magic in an extracted database file.

     - Parameter url: Extracted database file URL.
     - Returns: `true` when the file starts with SQLite's canonical header.
     - Side effects: Opens and reads the first 16 bytes of `url`.
     - Failure modes: File read failures return `false` so callers surface the existing invalid
       SQLite archive error.
     */
    private static func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: 16),
              data.count == 16 else {
            return false
        }
        return data == Data("SQLite format 3\u{0}".utf8)
    }

    /**
     Dispatches a validated supported backup section to its category-specific restore/import path.

     - Parameters:
       - section: Supported section selected by the user.
       - mode: Restore or Import operation.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Local settings store used by fidelity stores and sync reset.
     - Returns: User-visible row summary for the section.
     - Side effects: mutates local category data through the selected restore engine.
     - Failure modes: rethrows category restore/import failures; unsupported categories throw
       `AndroidDatabaseBackupError.unsupportedSelectedSection`.
     */
    private func applySupportedSection(
        _ section: AndroidDatabaseBackupSection,
        mode: AndroidDatabaseBackupApplyMode,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> String {
        switch section.category {
        case .bookmarks:
            let report = try applyBookmarks(section, mode: mode, modelContext: modelContext, settingsStore: settingsStore)
            return "\(report.restoredBibleBookmarkCount + report.restoredGenericBookmarkCount) bookmarks, \(report.restoredLabelCount) labels"
        case .readingPlans:
            let report = try applyReadingPlans(section, mode: mode, modelContext: modelContext, settingsStore: settingsStore)
            return "\(report.restoredPlanCodes.count) reading plans"
        case .workspaces:
            let report = try applyWorkspaces(section, mode: mode, modelContext: modelContext, settingsStore: settingsStore)
            return "\(report.restoredWorkspaceCount) workspaces, \(report.restoredWindowCount) windows"
        case .myDocuments:
            let report = try applyMyDocuments(
                section,
                mode: mode,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return "\(report.restoredDocumentCount) documents, \(report.restoredPageCount) pages"
        case .settings:
            let report = try AndroidDatabaseBackupSettingsMapper.restore(
                from: section.databaseFileURL,
                settingsStore: settingsStore
            )
            return "\(report.appliedSettingCount) settings"
        case .repositories:
            let report = try AndroidDatabaseBackupRepositoryMapper.restore(
                from: section.databaseFileURL,
                repositorySourceManager: repositorySourceManager,
                modelContext: modelContext
            )
            return "\(report.restoredRepositoryCount) repositories"
        case .progress:
            let report = try AndroidDatabaseBackupProgressMapper.apply(
                from: section.databaseFileURL,
                mode: mode,
                settingsStore: settingsStore
            )
            return "\(report.readingCount) readings, \(report.memorizedVerseCount) memorized verses, \(report.targetCount) targets"
        case .aiSettings:
            _ = try preservedDatabaseStore.restoreDatabase(
                from: section.databaseFileURL,
                category: .aiSettings
            )
            return "1 database"
        case .modules, .epubs:
            throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                section.category,
                section.support.explanation ?? "Unsupported by this iOS build."
            )
        }
    }

    /**
    Applies Android bookmark backup rows using restore or Android timestamp/log import semantics.

     - Parameters:
       - section: Extracted `bookmarks.sqlite3` section.
       - mode: Restore replaces local bookmarks; Import resolves duplicate rows using Android logs.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Settings store used for Android bookmark fidelity side stores.
     - Returns: Bookmark restore report from the shared Android restore engine.
     - Side effects: rewrites local bookmark SwiftData rows and bookmark fidelity settings. Import
       preserves quarantined local rows that are intentionally absent from trusted snapshots;
       restore remains an explicit destructive replacement.
     - Failure modes: rethrows malformed Android database or SwiftData save failures.
     */
    private func applyBookmarks(
        _ section: AndroidDatabaseBackupSection,
        mode: AndroidDatabaseBackupApplyMode,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkRestoreReport {
        let backupSnapshot = try bookmarkRestoreService.readSnapshot(from: section.databaseFileURL)
        let finalSnapshot: RemoteSyncAndroidBookmarkSnapshot
        switch mode {
        case .restore:
            finalSnapshot = backupSnapshot
        case .import:
            finalSnapshot = try mergeBookmarkSnapshots(
                local: currentBookmarkSnapshot(modelContext: modelContext, settingsStore: settingsStore),
                imported: backupSnapshot
            )
        }
        return try bookmarkRestoreService.replaceLocalBookmarks(
            from: finalSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore,
            preserveUnverifiedLocalBookmarks: mode == .import
        )
    }

    /**
     Applies Android reading-plan backup rows using restore or local-first import semantics.

     - Parameters:
       - section: Extracted `readingplans.sqlite3` section.
       - mode: Restore replaces local plans; Import adds missing plan/status rows only.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Settings store used for preserved Android status payloads.
     - Returns: Reading-plan restore report from the shared Android restore engine.
     - Side effects: rewrites local reading-plan SwiftData rows and preserved status settings.
     - Failure modes: rethrows unsupported plan definitions, malformed status JSON, or save failures.
     */
    private func applyReadingPlans(
        _ section: AndroidDatabaseBackupSection,
        mode: AndroidDatabaseBackupApplyMode,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncReadingPlanRestoreReport {
        let backupSnapshot = try readingPlanRestoreService.readSnapshot(from: section.databaseFileURL)
        let finalSnapshot: RemoteSyncAndroidReadingPlanSnapshot
        switch mode {
        case .restore:
            finalSnapshot = backupSnapshot
        case .import:
            finalSnapshot = mergeReadingPlanSnapshots(
                local: currentReadingPlanSnapshot(modelContext: modelContext, settingsStore: settingsStore),
                imported: backupSnapshot
            )
        }
        return try readingPlanRestoreService.replaceLocalReadingPlans(
            from: finalSnapshot,
            modelContext: modelContext,
            statusStore: RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        )
    }

    /**
     Applies Android workspace backup rows using restore or local-first import semantics.

     - Parameters:
       - section: Extracted `workspaces.sqlite3` section.
       - mode: Restore replaces local workspaces; Import adds missing workspace/window/history rows.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Settings store used for Android workspace fidelity side stores.
     - Returns: Workspace restore report from the shared Android restore engine.
     - Side effects: rewrites local workspace SwiftData rows and workspace fidelity settings.
     - Failure modes: rethrows archive/file generation mismatches, malformed serialized values,
       orphan references, or save failures.
     */
    private func applyWorkspaces(
        _ section: AndroidDatabaseBackupSection,
        mode: AndroidDatabaseBackupApplyMode,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncWorkspaceRestoreReport {
        let backupSnapshot = try workspaceRestoreService.readSnapshot(
            from: section.databaseFileURL,
            expectedSourceVersion: section.databaseVersion
        )
        let finalSnapshot: RemoteSyncAndroidWorkspaceSnapshot
        switch mode {
        case .restore:
            finalSnapshot = backupSnapshot
        case .import:
            finalSnapshot = mergeWorkspaceSnapshots(
                local: currentWorkspaceSnapshot(modelContext: modelContext, settingsStore: settingsStore),
                imported: backupSnapshot
            )
        }
        return try workspaceRestoreService.replaceLocalWorkspaces(
            from: finalSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Applies Android My Documents backup rows using restore or local-first import semantics.

     - Parameters:
       - section: Extracted `mydocuments.sqlite3` section.
       - mode: Restore replaces local documents; Import adds missing document/page/content rows.
       - modelContext: SwiftData context to mutate.
       - settingsStore: Settings store required for current-state Android key projection.
     - Returns: My Documents restore report from the shared Android restore engine.
     - Side effects: rewrites local My Documents SwiftData rows.
     - Failure modes: rethrows Android database validation, current local snapshot, or save failures.
     */
    private func applyMyDocuments(
        _ section: AndroidDatabaseBackupSection,
        mode: AndroidDatabaseBackupApplyMode,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncMyDocumentRestoreReport {
        let backupSnapshot = try myDocumentRestoreService.readSnapshot(from: section.databaseFileURL)
        let finalSnapshot: RemoteSyncAndroidMyDocumentSnapshot
        switch mode {
        case .restore:
            finalSnapshot = backupSnapshot
        case .import:
            finalSnapshot = try mergeMyDocumentSnapshots(
                local: currentMyDocumentSnapshot(modelContext: modelContext, settingsStore: settingsStore),
                imported: backupSnapshot
            )
        }
        return try myDocumentRestoreService.replaceLocalMyDocuments(from: finalSnapshot, modelContext: modelContext)
    }

    /**
     Clears Android-aligned remote-sync bookkeeping after a manual backup apply.

     Manual Restore/Import changes local data outside the remote patch stream. Android disables and
     clears affected sync state after such restores so later sync cannot treat the restored rows as
     already reconciled remote state; iOS mirrors that category-scoped behavior here.

     - Parameters:
       - category: Remote-sync category affected by the manual backup operation.
       - settingsStore: Settings store containing sync toggles and metadata rows.
     - Side effects: disables sync and clears bootstrap, patch status, log-entry, and fingerprint
       rows for the category.
     - Failure modes: underlying settings-store writes are best effort.
     */
    private func resetManualBackupSyncState(for category: RemoteSyncCategory, settingsStore: SettingsStore) {
        RemoteSyncSettingsStore(settingsStore: settingsStore).setSyncEnabled(false, for: category)
        RemoteSyncStateStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncPatchStatusStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncLogEntryStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).clearCategory(category)
    }

    /**
     Creates a unique temporary file URL for Android database backup staging.

     - Parameters:
       - prefix: Filename prefix describing the staging purpose.
       - suffix: Filename extension or suffix required by the staged file type.
     - Returns: URL beneath the service's configured temporary directory.
     - Side effects: none.
     - Failure modes: This helper cannot fail; file creation happens at the call site.
     */
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Reads current local bookmarks as a direct Android restore snapshot for Import merging.

     - Parameters:
       - modelContext: SwiftData context that owns local bookmark rows.
       - settingsStore: Settings store used for preserved Android bookmark fidelity.
     - Returns: Android-shaped bookmark snapshot sorted deterministically.
     - Side effects: reads SwiftData and local fidelity settings.
     - Failure modes: underlying snapshot service treats fetch failures as an empty snapshot.
     */
    private func currentBookmarkSnapshot(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncAndroidBookmarkSnapshot {
        let current = bookmarkSnapshotService.snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        return RemoteSyncAndroidBookmarkSnapshot(
            labels: current.labelRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            bibleBookmarks: current.bibleBookmarkRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            genericBookmarks: current.genericBookmarkRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            studyPadEntries: current.studyPadEntryRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            logEntries: RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entries(for: .bookmarks)
                .map(AndroidBookmarkDatabaseContract.normalizedLogEntry)
        )
    }

    /**
     Merges bookmark snapshots with Android's strict per-row log timestamp behavior.

     - Parameters:
       - local: Current local bookmark rows projected into Android form.
       - imported: Backup bookmark rows read from Android's database.
     - Returns: Snapshot containing accepted imported rows and unaffected local rows.
     - Side effects: none.
     - Failure modes: Throws when an accepted upsert log lacks its source row or a log key is malformed.
     */
    private func mergeBookmarkSnapshots(
        local: RemoteSyncAndroidBookmarkSnapshot,
        imported: RemoteSyncAndroidBookmarkSnapshot
    ) throws -> RemoteSyncAndroidBookmarkSnapshot {
        try AndroidBookmarkSnapshotMergeService().merge(local: local, imported: imported)
    }

    /**
     Reads current local reading plans as a direct Android restore snapshot for Import merging.

     - Parameters:
       - modelContext: SwiftData context that owns local reading-plan rows.
       - settingsStore: Settings store containing preserved Android status payloads.
     - Returns: Android-shaped reading-plan snapshot.
     - Side effects: reads SwiftData and local status-fidelity settings.
     - Failure modes: underlying snapshot service treats fetch failures as an empty snapshot.
     */
    private func currentReadingPlanSnapshot(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncAndroidReadingPlanSnapshot {
        let current = readingPlanSnapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let statuses = current.statusRowsByKey.values.map {
            RemoteSyncAndroidReadingPlanStatus(
                id: $0.id,
                planCode: $0.planCode,
                dayNumber: $0.planDay,
                readingStatusJSON: $0.readingStatusJSON
            )
        }
        let statusesByPlanCode = Dictionary(grouping: statuses, by: \.planCode)
        let plans = current.planRowsByKey.values.map { row in
            RemoteSyncAndroidReadingPlan(
                id: row.id,
                planCode: row.planCode,
                startDate: Date(timeIntervalSince1970: Double(row.planStartDateMillis) / 1000.0),
                currentDay: row.planCurrentDay,
                statuses: statusesByPlanCode[row.planCode, default: []]
            )
        }
        return RemoteSyncAndroidReadingPlanSnapshot(plans: plans, orphanStatuses: [])
    }

    /**
     Reads current local My Documents as a direct Android restore snapshot for Import merging.

     This path uses the throwing snapshot variant because treating a failed local fetch as empty
     would make Import behave like Restore and risk data loss.

     - Parameters:
       - modelContext: SwiftData context that owns local My Documents rows.
       - settingsStore: Settings store used for Android log-key projection.
     - Returns: Android-shaped My Documents snapshot.
     - Side effects: reads SwiftData rows.
     - Failure modes: rethrows SwiftData fetch failures from the snapshot service.
     */
    private func currentMyDocumentSnapshot(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAndroidMyDocumentSnapshot {
        let current = try myDocumentSnapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        return RemoteSyncAndroidMyDocumentSnapshot(
            documents: current.documentRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            pages: current.pageRowsByKey.values.sorted { $0.id.uuidString < $1.id.uuidString },
            pageContents: current.pageContentRowsByKey.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            aiPageCacheEntries: current.aiPageCacheEntryRowsByKey.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            orphanReferences: []
        )
    }

    /**
     Merges reading-plan snapshots with Android Import's local-first uniqueness behavior.

     - Parameters:
       - local: Current local reading-plan rows projected into Android form.
       - imported: Backup reading-plan rows read from Android's database.
     - Returns: Snapshot preserving local plans/statuses and adding imported missing rows.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func mergeReadingPlanSnapshots(
        local: RemoteSyncAndroidReadingPlanSnapshot,
        imported: RemoteSyncAndroidReadingPlanSnapshot
    ) -> RemoteSyncAndroidReadingPlanSnapshot {
        var plansByCode = Dictionary(uniqueKeysWithValues: local.plans.map { ($0.planCode, $0) })
        for plan in imported.plans where plansByCode[plan.planCode] == nil {
            plansByCode[plan.planCode] = plan
        }

        var statusesByKey: [String: RemoteSyncAndroidReadingPlanStatus] = [:]
        for status in local.plans.flatMap(\.statuses) {
            statusesByKey["\(status.planCode)#\(status.dayNumber)"] = status
        }
        for status in imported.plans.flatMap(\.statuses) where statusesByKey["\(status.planCode)#\(status.dayNumber)"] == nil {
            statusesByKey["\(status.planCode)#\(status.dayNumber)"] = status
        }
        let statusesByPlanCode = Dictionary(grouping: statusesByKey.values, by: \.planCode)
        let plans = plansByCode.values.map { plan in
            RemoteSyncAndroidReadingPlan(
                id: plan.id,
                planCode: plan.planCode,
                startDate: plan.startDate,
                currentDay: plan.currentDay,
                statuses: statusesByPlanCode[plan.planCode, default: []].sorted { $0.dayNumber < $1.dayNumber }
            )
        }
        return RemoteSyncAndroidReadingPlanSnapshot(
            plans: plans.sorted { $0.planCode < $1.planCode },
            orphanStatuses: []
        )
    }

    /**
     Reads current local workspaces as a direct Android restore snapshot for Import merging.

     The local model does not store Android history IDs directly, so the workspace fidelity store is
     used when available and deterministic negative IDs are assigned for local-only history rows.

     - Parameters:
       - modelContext: SwiftData context that owns workspace, window, page-manager, and history rows.
       - settingsStore: Settings store containing Android workspace fidelity aliases.
     - Returns: Android-shaped workspace snapshot sorted in display order.
     - Side effects: reads SwiftData and workspace fidelity settings.
     - Failure modes: SwiftData fetch failures are treated as an empty workspace list, matching the
       existing non-throwing outbound snapshot style.
     */
    private func currentWorkspaceSnapshot(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncAndroidWorkspaceSnapshot {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let workspaceFidelityByID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allWorkspaceEntries().map { ($0.workspaceID, $0) }
        )
        let pageManagerFidelityByWindowID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allPageManagerEntries().map { ($0.windowID, $0) }
        )
        let historyAliasByLocalID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allHistoryItemAliases().map { ($0.localHistoryItemID, $0.remoteHistoryItemID) }
        )
        let workspaces = ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? [])
            .sorted { lhs, rhs in
                if lhs.orderNumber == rhs.orderNumber {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.orderNumber < rhs.orderNumber
            }

        var generatedRemoteHistoryID: Int64 = -1
        let androidWorkspaces = workspaces.map { workspace in
            let windows = (workspace.windows ?? []).sorted { lhs, rhs in
                if lhs.orderNumber == rhs.orderNumber {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.orderNumber < rhs.orderNumber
            }.map { window in
                let pageManager = window.pageManager
                let pageFidelity = pageManagerFidelityByWindowID[window.id]
                let androidPageManager = RemoteSyncAndroidWorkspacePageManager(
                    windowID: window.id,
                    bibleDocument: pageManager?.bibleDocument,
                    bibleVersification: pageManager?.bibleVersification,
                    bibleBook: pageManager?.bibleBibleBook,
                    bibleChapterNo: pageManager?.bibleChapterNo,
                    bibleVerseNo: pageManager?.bibleVerseNo,
                    commentaryDocument: pageManager?.commentaryDocument,
                    commentaryAnchorOrdinal: pageManager?.commentaryAnchorOrdinal,
                    commentarySourceBookAndKey: pageFidelity?.commentarySourceBookAndKey,
                    dictionaryDocument: pageManager?.dictionaryDocument,
                    dictionaryKey: pageManager?.dictionaryKey,
                    dictionaryAnchorOrdinal: pageFidelity?.dictionaryAnchorOrdinal,
                    generalBookDocument: pageManager?.generalBookDocument,
                    generalBookKey: pageManager?.generalBookKey,
                    generalBookAnchorOrdinal: pageFidelity?.generalBookAnchorOrdinal,
                    mapDocument: pageManager?.mapDocument,
                    mapKey: pageManager?.mapKey,
                    mapAnchorOrdinal: pageFidelity?.mapAnchorOrdinal,
                    currentCategoryName: pageFidelity?.rawCurrentCategoryName
                        ?? (pageManager?.currentCategoryName.uppercased() ?? "BIBLE"),
                    textDisplaySettings: pageManager?.textDisplaySettings,
                    jsState: pageManager?.jsState
                )
                let historyItems = (window.historyItems ?? []).sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.createdAt < rhs.createdAt
                }.map { item in
                    let remoteID = historyAliasByLocalID[item.id] ?? {
                        defer { generatedRemoteHistoryID -= 1 }
                        return generatedRemoteHistoryID
                    }()
                    return RemoteSyncAndroidWorkspaceHistoryItem(
                        remoteID: remoteID,
                        windowID: window.id,
                        createdAt: item.createdAt,
                        document: item.document,
                        key: item.key,
                        anchorOrdinal: item.anchorOrdinal
                    )
                }
                return RemoteSyncAndroidWorkspaceWindow(
                    id: window.id,
                    workspaceID: workspace.id,
                    isSynchronized: window.isSynchronized,
                    isPinMode: window.isPinMode,
                    isLinksWindow: window.isLinksWindow,
                    orderNumber: window.orderNumber,
                    targetLinksWindowID: window.targetLinksWindowId,
                    syncGroup: window.syncGroup,
                    layoutState: window.layoutState,
                    layoutWeight: window.layoutWeight,
                    pageManager: androidPageManager,
                    historyItems: historyItems
                )
            }
            var workspaceSettings = workspace.workspaceSettings ?? WorkspaceSettings()
            workspaceSettings.normalizeAutoAssignPrimaryLabel()
            return RemoteSyncAndroidWorkspace(
                id: workspace.id,
                name: workspace.name,
                contentsText: workspace.contentsText,
                orderNumber: workspace.orderNumber,
                textDisplaySettings: workspace.textDisplaySettings,
                workspaceSettings: workspaceSettings,
                speakSettingsJSON: (try? workspaceSettings.speakSettings.androidJSON())
                    ?? workspaceFidelityByID[workspace.id]?.speakSettingsJSON,
                unPinnedWeight: workspace.unPinnedWeight,
                maximizedWindowID: workspace.maximizedWindowId,
                primaryTargetLinksWindowID: workspace.primaryTargetLinksWindowId,
                workspaceColor: workspace.workspaceColor,
                windows: windows
            )
        }
        return RemoteSyncAndroidWorkspaceSnapshot(workspaces: androidWorkspaces)
    }

    /**
     Merges workspace snapshots with Android Import's local-first uniqueness behavior.

     - Parameters:
       - local: Current local workspace rows projected into Android form.
       - imported: Backup workspace rows read from Android's database.
     - Returns: Snapshot preserving local workspaces/windows and adding imported missing children.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func mergeWorkspaceSnapshots(
        local: RemoteSyncAndroidWorkspaceSnapshot,
        imported: RemoteSyncAndroidWorkspaceSnapshot
    ) -> RemoteSyncAndroidWorkspaceSnapshot {
        var workspacesByID = Dictionary(uniqueKeysWithValues: local.workspaces.map { ($0.id, $0) })
        for workspace in imported.workspaces {
            if let existing = workspacesByID[workspace.id] {
                workspacesByID[workspace.id] = mergeWorkspace(local: existing, imported: workspace)
            } else {
                workspacesByID[workspace.id] = workspace
            }
        }
        return RemoteSyncAndroidWorkspaceSnapshot(
            workspaces: workspacesByID.values.sorted {
                if $0.orderNumber == $1.orderNumber {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.orderNumber < $1.orderNumber
            }
        )
    }

    /**
     Merges one duplicate workspace while preserving local workspace-level fields.

     - Parameters:
       - local: Existing local Android-shaped workspace.
       - imported: Imported workspace with the same ID.
     - Returns: Workspace with local metadata and unioned windows/history.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func mergeWorkspace(
        local: RemoteSyncAndroidWorkspace,
        imported: RemoteSyncAndroidWorkspace
    ) -> RemoteSyncAndroidWorkspace {
        var windowsByID = Dictionary(uniqueKeysWithValues: local.windows.map { ($0.id, $0) })
        for window in imported.windows {
            if let existing = windowsByID[window.id] {
                windowsByID[window.id] = mergeWorkspaceWindow(local: existing, imported: window)
            } else {
                windowsByID[window.id] = window
            }
        }
        return RemoteSyncAndroidWorkspace(
            id: local.id,
            name: local.name,
            contentsText: local.contentsText,
            orderNumber: local.orderNumber,
            textDisplaySettings: local.textDisplaySettings,
            workspaceSettings: local.workspaceSettings,
            speakSettingsJSON: local.speakSettingsJSON ?? imported.speakSettingsJSON,
            unPinnedWeight: local.unPinnedWeight,
            maximizedWindowID: local.maximizedWindowID,
            primaryTargetLinksWindowID: local.primaryTargetLinksWindowID,
            workspaceColor: local.workspaceColor,
            windows: windowsByID.values.sorted {
                if $0.orderNumber == $1.orderNumber {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.orderNumber < $1.orderNumber
            }
        )
    }

    /**
     Merges one duplicate workspace window while preserving local page-manager state.

     - Parameters:
       - local: Existing local Android-shaped window.
       - imported: Imported window with the same ID.
     - Returns: Window with local fields and imported missing history rows.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func mergeWorkspaceWindow(
        local: RemoteSyncAndroidWorkspaceWindow,
        imported: RemoteSyncAndroidWorkspaceWindow
    ) -> RemoteSyncAndroidWorkspaceWindow {
        var historyByRemoteID = Dictionary(uniqueKeysWithValues: local.historyItems.map { ($0.remoteID, $0) })
        for history in imported.historyItems where historyByRemoteID[history.remoteID] == nil {
            historyByRemoteID[history.remoteID] = history
        }
        return RemoteSyncAndroidWorkspaceWindow(
            id: local.id,
            workspaceID: local.workspaceID,
            isSynchronized: local.isSynchronized,
            isPinMode: local.isPinMode,
            isLinksWindow: local.isLinksWindow,
            orderNumber: local.orderNumber,
            targetLinksWindowID: local.targetLinksWindowID,
            syncGroup: local.syncGroup,
            layoutState: local.layoutState,
            layoutWeight: local.layoutWeight,
            pageManager: local.pageManager,
            historyItems: historyByRemoteID.values.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.remoteID < $1.remoteID
                }
                return $0.createdAt < $1.createdAt
            }
        )
    }

    /**
     Merges My Documents snapshots with Android Import's local-first uniqueness behavior.

     Document IDs, document initials, page IDs, page keys, content page IDs, and cache page IDs are
     treated as Android uniqueness boundaries. Imported children whose parent rows are not present
     after the merge are skipped to preserve Android foreign-key safety.

     - Parameters:
       - local: Current local My Documents rows projected into Android form.
       - imported: Backup My Documents rows read from Android's database.
     - Returns: Snapshot preserving local rows and adding imported rows whose uniqueness keys are
       absent and whose parents exist.
     - Side effects: none.
     - Failure modes: This helper currently cannot fail; it is marked throwing to preserve room for
       stricter validation without changing callers.
     */
    private func mergeMyDocumentSnapshots(
        local: RemoteSyncAndroidMyDocumentSnapshot,
        imported: RemoteSyncAndroidMyDocumentSnapshot
    ) throws -> RemoteSyncAndroidMyDocumentSnapshot {
        var documentsByID = Dictionary(uniqueKeysWithValues: local.documents.map { ($0.id, $0) })
        var documentInitials = Set(local.documents.map(\.initials))
        for document in imported.documents where documentsByID[document.id] == nil && !documentInitials.contains(document.initials) {
            documentsByID[document.id] = document
            documentInitials.insert(document.initials)
        }

        var pagesByID = Dictionary(uniqueKeysWithValues: local.pages.map { ($0.id, $0) })
        var pageKeys = Set(local.pages.map { "\($0.documentId.uuidString)#\($0.pageKey)" })
        let validDocumentIDs = Set(documentsByID.keys)
        for page in imported.pages
            where pagesByID[page.id] == nil
                && validDocumentIDs.contains(page.documentId)
                && !pageKeys.contains("\(page.documentId.uuidString)#\(page.pageKey)") {
            pagesByID[page.id] = page
            pageKeys.insert("\(page.documentId.uuidString)#\(page.pageKey)")
        }

        var contentsByPageID = Dictionary(uniqueKeysWithValues: local.pageContents.map { ($0.pageId, $0) })
        let validPageIDs = Set(pagesByID.keys)
        for content in imported.pageContents where contentsByPageID[content.pageId] == nil && validPageIDs.contains(content.pageId) {
            contentsByPageID[content.pageId] = content
        }

        var cacheEntriesByPageID = Dictionary(uniqueKeysWithValues: local.aiPageCacheEntries.map { ($0.pageId, $0) })
        for cacheEntry in imported.aiPageCacheEntries where cacheEntriesByPageID[cacheEntry.pageId] == nil && validPageIDs.contains(cacheEntry.pageId) {
            cacheEntriesByPageID[cacheEntry.pageId] = cacheEntry
        }

        return RemoteSyncAndroidMyDocumentSnapshot(
            documents: documentsByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            pages: pagesByID.values.sorted { $0.id.uuidString < $1.id.uuidString },
            pageContents: contentsByPageID.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            aiPageCacheEntries: cacheEntriesByPageID.values.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            orphanReferences: []
        )
    }
}
