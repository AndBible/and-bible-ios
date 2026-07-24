// AndroidStudyPadArchiveService.swift -- Android STUDYPAD_EXPORT archive interoperability

import Foundation
import SQLite3
import SwiftData

/// Errors raised while exporting, inspecting, or importing Android Study Pad archives.
public enum AndroidStudyPadArchiveError: LocalizedError, Equatable {
    case emptySelection
    case missingSelectedLabels
    case invalidArchive(String)
    case missingManifest
    case manifestNotFirst
    case duplicateManifest
    case unsupportedBackupType(String)
    case unsupportedManifestVersion(Int)
    case missingBookmarksDeclaration
    case missingBookmarksDatabase
    case invalidSQLiteDatabase(String)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one Study Pad to export."
        case .missingSelectedLabels:
            return "One or more selected Study Pad labels no longer exist."
        case .invalidArchive(let reason):
            return "The Study Pad archive is invalid: \(reason)"
        case .missingManifest:
            return "The archive does not contain AndBibleBackupManifest.json."
        case .manifestNotFirst:
            return "AndBibleBackupManifest.json must be the first archive entry."
        case .duplicateManifest:
            return "The archive contains more than one backup manifest."
        case .unsupportedBackupType(let type):
            return "Expected a STUDYPAD_EXPORT archive, but found \(type)."
        case .unsupportedManifestVersion(let version):
            return "Study Pad archive manifest version \(version) is not supported."
        case .missingBookmarksDeclaration:
            return "The Study Pad archive manifest does not declare BOOKMARKS content."
        case .missingBookmarksDatabase:
            return "The Study Pad archive does not contain db/bookmarks.sqlite3."
        case .invalidSQLiteDatabase(let reason):
            return "The Study Pad bookmark database is invalid: \(reason)"
        }
    }
}

/** File-backed Android Study Pad export ready for a platform save/share handoff. */
public struct AndroidStudyPadArchiveExport: Sendable, Equatable {
    /// Android-compatible archive filename.
    public let fileName: String

    /// Complete temporary `.abdb.zip` archive; caller owns cleanup.
    public let fileURL: URL

    /// Persisted label identifiers copied into the archive.
    public let labelIDs: [UUID]

    /** Creates one immutable export result without further side effects. */
    public init(fileName: String, fileURL: URL, labelIDs: [UUID]) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.labelIDs = labelIDs
    }
}

/** Counts displayed before an inspected Android Study Pad archive is imported. */
public struct AndroidStudyPadArchiveSummary: Sendable, Equatable {
    public let labelCount: Int
    public let bibleBookmarkCount: Int
    public let genericBookmarkCount: Int
    public let textEntryCount: Int

    /** Creates one immutable inspection summary without side effects. */
    public init(
        labelCount: Int,
        bibleBookmarkCount: Int,
        genericBookmarkCount: Int,
        textEntryCount: Int
    ) {
        self.labelCount = labelCount
        self.bibleBookmarkCount = bibleBookmarkCount
        self.genericBookmarkCount = genericBookmarkCount
        self.textEntryCount = textEntryCount
    }
}

/**
 Validated Android Study Pad archive staged through the shared database-backup loader.

 The value owns `archive.temporaryDirectory`; callers must invoke
 `AndroidStudyPadArchiveService.cleanup(_:)` after cancellation or apply completion.
 */
public struct AndroidStudyPadArchiveInspection: Identifiable, Sendable {
    public let id: UUID
    public let archive: AndroidDatabaseBackupArchive
    public let summary: AndroidStudyPadArchiveSummary

    /** Creates one validated staged inspection without additional side effects. */
    public init(
        id: UUID = UUID(),
        archive: AndroidDatabaseBackupArchive,
        summary: AndroidStudyPadArchiveSummary
    ) {
        self.id = id
        self.archive = archive
        self.summary = summary
    }
}

/**
 Composes existing Android database, ZIP, and restore owners into `STUDYPAD_EXPORT` behavior.

 Export starts from the canonical Room-v12 bookmark database builder, projects only selected labels
 and their linked Bible/generic bookmarks, notes, junctions, and Study Pad text, fixes missing
 primary labels, and writes Android's two-entry archive. Import first validates the specialized
 manifest contract, then delegates non-destructive bookmark merging and sync-state reset to
 `AndroidDatabaseBackupService`.

 Inputs:
 - selected persisted label IDs and a SwiftData context for export
 - user-selected archive URL and a SwiftData context for import

 Outputs:
 - file-backed Android archive export
 - staged import inspection and shared apply report

 Side effects:
 - creates and removes temporary SQLite/ZIP files
 - import mutates local bookmark/label/Study Pad data through the shared backup service

 Failure modes:
 - rejects empty/stale selection, malformed ZIPs, duplicate/missing manifests, any backup type other
 than `STUDYPAD_EXPORT`, unsupported versions, missing BOOKMARKS declarations/files, invalid Room
 databases, and shared restore failures
 */
public final class AndroidStudyPadArchiveService {
    public static let backupType = "STUDYPAD_EXPORT"
    public static let manifestFileName = "AndBibleBackupManifest.json"
    public static let bookmarksEntryName = "db/bookmarks.sqlite3"
    public static let multipleStudyPadsFileName = "StudyPads.abdb.zip"

    private static let maximumManifestByteCount = 1024 * 1024

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let databaseBackupService: AndroidDatabaseBackupService
    private let bookmarkRestoreService: RemoteSyncBookmarkRestoreService
    private let producerVersion: Int

    /**
     Creates a Study Pad archive service from the shared backup/restore collaborators.

     - Parameters:
       - fileManager: Temporary archive and database filesystem owner.
       - temporaryDirectory: Optional scratch root.
       - databaseBackupService: Existing archive loader/apply engine.
       - bookmarkRestoreService: Existing Room snapshot reader used for pre-import counts.
       - producerVersion: Optional integer producer build; defaults to the current app bundle build.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        databaseBackupService: AndroidDatabaseBackupService? = nil,
        bookmarkRestoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        producerVersion: Int? = nil
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.databaseBackupService = databaseBackupService ?? AndroidDatabaseBackupService(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
        self.bookmarkRestoreService = bookmarkRestoreService
        self.producerVersion = producerVersion ?? AndroidBackupManifestCodec.producerVersion()
    }

    /**
     Exports selected labels using Android's exact specialized archive shape.

     - Parameters:
       - labelIDs: Non-empty selected label IDs in dialog order.
       - modelContext: Context containing current bookmark-category state.
     - Returns: File-backed archive with Android filename semantics.
     - Side effects: Builds and filters a temporary Room database, writes a temporary ZIP, and
       removes the intermediate database.
     - Failure modes: Throws for empty/stale selection and builder, SQLite, JSON, or ZIP failures.
     */
    public func exportArchiveFile(
        labelIDs: [UUID],
        modelContext: ModelContext
    ) throws -> AndroidStudyPadArchiveExport {
        guard !labelIDs.isEmpty else { throw AndroidStudyPadArchiveError.emptySelection }
        let selectedIDSet = Set(labelIDs)
        let labels = try modelContext.fetch(FetchDescriptor<Label>())
            .filter { selectedIDSet.contains($0.id) }
        guard labels.count == selectedIDSet.count else {
            throw AndroidStudyPadArchiveError.missingSelectedLabels
        }

        let settingsStore = SettingsStore(modelContext: modelContext)
        let databaseURL = try RemoteSyncInitialBackupUploadService.buildAndroidDatabaseBackupDatabase(
            for: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: AndroidDatabaseBackupCategory.bookmarks.supportedDatabaseVersion,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
        defer { try? fileManager.removeItem(at: databaseURL) }

        try projectSelectedStudyPads(in: databaseURL, labelIDs: selectedIDSet)

        let manifestData = try AndroidBackupManifestCodec.encode(
            backupType: Self.backupType,
            contains: [AndroidDatabaseBackupCategory.bookmarks.rawValue],
            andBibleVersion: producerVersion
        )
        let archiveURL = temporaryURL(prefix: "android-study-pad-export-", suffix: ".abdb.zip")
        do {
            try ZipArchiveWriter.writeStoredArchive(
                entries: [
                    ZipArchiveWriterFileEntry(name: Self.manifestFileName, data: manifestData),
                    ZipArchiveWriterFileEntry(name: Self.bookmarksEntryName, fileURL: databaseURL),
                ],
                to: archiveURL,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }

        let fileName: String
        if labels.count == 1, let name = labels.first?.name {
            fileName = Self.sanitizedFileName(name) + AndroidDatabaseBackupService.databaseBackupSuffix
        } else {
            fileName = Self.multipleStudyPadsFileName
        }
        return AndroidStudyPadArchiveExport(fileName: fileName, fileURL: archiveURL, labelIDs: labelIDs)
    }

    /**
     Validates and stages one Android `STUDYPAD_EXPORT` archive.

     - Parameter archiveURL: User-selected file-backed archive.
     - Returns: Staged shared backup archive plus exact bookmark-category row counts.
     - Side effects: Reads ZIP metadata and creates a temporary extracted database directory.
     - Failure modes: Rejects malformed/ambiguous archives or any non-Study-Pad manifest before the
       shared loader can treat the bookmark database as a generic manual backup.
     */
    public func inspectImport(at archiveURL: URL) throws -> AndroidStudyPadArchiveInspection {
        let entries: [ZipArchiveFileEntry]
        do {
            entries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        } catch {
            throw AndroidStudyPadArchiveError.invalidArchive(error.localizedDescription)
        }

        let manifests = entries.filter { $0.name == Self.manifestFileName }
        guard !manifests.isEmpty else { throw AndroidStudyPadArchiveError.missingManifest }
        guard manifests.count == 1 else { throw AndroidStudyPadArchiveError.duplicateManifest }
        guard entries.first?.name == Self.manifestFileName else {
            throw AndroidStudyPadArchiveError.manifestNotFirst
        }
        guard entries.filter({ $0.name == Self.bookmarksEntryName }).count == 1 else {
            throw AndroidStudyPadArchiveError.missingBookmarksDatabase
        }

        let manifestData: Data
        do {
            manifestData = try ZipArchiveReader.data(
                for: manifests[0],
                inArchiveAt: archiveURL,
                maximumByteCount: Self.maximumManifestByteCount,
                fileManager: fileManager
            )
        } catch {
            throw AndroidStudyPadArchiveError.invalidArchive(error.localizedDescription)
        }
        let manifest: AndroidBackupManifestPayload
        do {
            manifest = try AndroidBackupManifestCodec.decodeUsingAndroidDefaults(manifestData)
        } catch {
            throw AndroidStudyPadArchiveError.invalidArchive(error.localizedDescription)
        }
        guard manifest.backupType == Self.backupType else {
            throw AndroidStudyPadArchiveError.unsupportedBackupType(manifest.backupType)
        }
        let version = manifest.manifestVersion ?? 1
        guard version <= 1 else {
            throw AndroidStudyPadArchiveError.unsupportedManifestVersion(version)
        }
        guard manifest.contains?.contains(AndroidDatabaseBackupCategory.bookmarks.rawValue) == true else {
            throw AndroidStudyPadArchiveError.missingBookmarksDeclaration
        }

        let archive = try databaseBackupService.loadArchive(fromArchiveAt: archiveURL)
        do {
            guard let section = archive.sections.first(where: { $0.category == .bookmarks }) else {
                databaseBackupService.cleanup(archive)
                throw AndroidStudyPadArchiveError.missingBookmarksDatabase
            }
            guard section.support.isSupported else {
                databaseBackupService.cleanup(archive)
                throw AndroidStudyPadArchiveError.invalidSQLiteDatabase(
                    section.support.explanation ?? "Unsupported Android bookmark database."
                )
            }
            let snapshot = try bookmarkRestoreService.readSnapshot(from: section.databaseFileURL)
            return AndroidStudyPadArchiveInspection(
                archive: archive,
                summary: AndroidStudyPadArchiveSummary(
                    labelCount: snapshot.labels.count,
                    bibleBookmarkCount: snapshot.bibleBookmarks.count,
                    genericBookmarkCount: snapshot.genericBookmarks.count,
                    textEntryCount: snapshot.studyPadEntries.count
                )
            )
        } catch {
            databaseBackupService.cleanup(archive)
            throw error
        }
    }

    /**
     Imports a previously inspected Study Pad archive through the shared bookmark merge engine.

     - Parameters:
       - inspection: Validated staged archive.
       - modelContext: Local SwiftData context to merge into.
     - Returns: Shared Android backup apply report.
     - Side effects: Merges bookmark-category rows and resets manual-backup sync state.
     - Failure modes: Rethrows shared restore and persistence failures; caller still owns cleanup.
     */
    public func applyImport(
        _ inspection: AndroidStudyPadArchiveInspection,
        modelContext: ModelContext
    ) throws -> AndroidDatabaseBackupApplyReport {
        try databaseBackupService.apply(
            archive: inspection.archive,
            selections: [AndroidDatabaseBackupSelection(category: .bookmarks, mode: .import)],
            modelContext: modelContext,
            settingsStore: SettingsStore(modelContext: modelContext)
        )
    }

    /** Removes temporary files owned by a staged inspection. */
    public func cleanup(_ inspection: AndroidStudyPadArchiveInspection) {
        databaseBackupService.cleanup(inspection.archive)
    }

    /** Removes a temporary file-backed export after save/share completion or cancellation. */
    public func cleanup(_ export: AndroidStudyPadArchiveExport) {
        try? fileManager.removeItem(at: export.fileURL)
    }

    /** Android's filename sanitization used by a single-label export. */
    public static func sanitizedFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    /// Filters a complete Room-v12 bookmark database to Android's selected Study Pad projection.
    private func projectSelectedStudyPads(in databaseURL: URL, labelIDs: Set<UUID>) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw AndroidStudyPadArchiveError.invalidSQLiteDatabase("Unable to open bookmarks.sqlite3.")
        }
        defer { sqlite3_close(database) }

        let selected = labelIDs
            .sorted { $0.uuidString < $1.uuidString }
            .map { "x'\($0.uuidString.replacingOccurrences(of: "-", with: ""))'" }
            .joined(separator: ",")

        do {
            try execute("PRAGMA foreign_keys=OFF", database: database)
            try execute("BEGIN IMMEDIATE", database: database)
            try execute(
                "DELETE FROM StudyPadTextEntryText WHERE studyPadTextEntryId NOT IN " +
                "(SELECT id FROM StudyPadTextEntry WHERE labelId IN (\(selected)))",
                database: database
            )
            try execute("DELETE FROM StudyPadTextEntry WHERE labelId NOT IN (\(selected))", database: database)
            try execute("DELETE FROM BibleBookmarkToLabel WHERE labelId NOT IN (\(selected))", database: database)
            try execute("DELETE FROM GenericBookmarkToLabel WHERE labelId NOT IN (\(selected))", database: database)
            try execute(
                "DELETE FROM BibleBookmarkNotes WHERE bookmarkId NOT IN " +
                "(SELECT bookmarkId FROM BibleBookmarkToLabel)",
                database: database
            )
            try execute(
                "DELETE FROM GenericBookmarkNotes WHERE bookmarkId NOT IN " +
                "(SELECT bookmarkId FROM GenericBookmarkToLabel)",
                database: database
            )
            try execute(
                "DELETE FROM BibleBookmark WHERE id NOT IN (SELECT bookmarkId FROM BibleBookmarkToLabel)",
                database: database
            )
            try execute(
                "DELETE FROM GenericBookmark WHERE id NOT IN (SELECT bookmarkId FROM GenericBookmarkToLabel)",
                database: database
            )
            try execute("DELETE FROM Label WHERE id NOT IN (\(selected))", database: database)
            try execute(
                "UPDATE BibleBookmark SET primaryLabelId=NULL WHERE primaryLabelId IS NOT NULL " +
                "AND primaryLabelId NOT IN (SELECT id FROM Label)",
                database: database
            )
            try execute(
                "UPDATE GenericBookmark SET primaryLabelId=NULL WHERE primaryLabelId IS NOT NULL " +
                "AND primaryLabelId NOT IN (SELECT id FROM Label)",
                database: database
            )
            try execute("DELETE FROM LogEntry", database: database)
            try execute("DELETE FROM SyncConfiguration", database: database)
            try execute("DELETE FROM SyncStatus", database: database)
            try execute("COMMIT", database: database)
            try execute("PRAGMA foreign_keys=ON", database: database)
            guard try foreignKeyViolationCount(database: database) == 0 else {
                throw AndroidStudyPadArchiveError.invalidSQLiteDatabase("Foreign-key validation failed.")
            }
        } catch {
            _ = try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    /// Executes one SQLite statement and preserves the native error reason.
    private func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AndroidStudyPadArchiveError.invalidSQLiteDatabase(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Counts foreign-key violations after the selection projection commits.
    private func foreignKeyViolationCount(database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM pragma_foreign_key_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AndroidStudyPadArchiveError.invalidSQLiteDatabase(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AndroidStudyPadArchiveError.invalidSQLiteDatabase(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Creates one unique temporary file URL without creating the file itself.
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString + suffix)
    }
}
