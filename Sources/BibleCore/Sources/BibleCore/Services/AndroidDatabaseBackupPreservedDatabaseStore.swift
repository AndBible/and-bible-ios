// AndroidDatabaseBackupPreservedDatabaseStore.swift -- Android-owned database preservation

import Foundation
import SQLite3

/**
 File-backed store for Android database backup categories that iOS does not semantically own yet.

 This store is intentionally not a mapper. It preserves a validated Android Room database byte-for-
 byte so manual Android backup/restore can round-trip categories whose user-facing feature has not
 been implemented natively on iOS. When iOS later owns a real model for one of these categories, that
 category should move to a semantic mapper instead of staying in this preservation store.
 */
public final class AndroidDatabaseBackupPreservedDatabaseStore {
    /// Android database categories that can be preserved opaquely by this store.
    public static let preservedCategories: Set<AndroidDatabaseBackupCategory> = [.aiSettings]

    private let fileManager: FileManager
    private let rootDirectory: URL

    /**
     Creates a file-backed preservation store.

     - Parameters:
       - fileManager: File manager used for directory creation and atomic replacement.
       - rootDirectory: Directory that owns preserved Android database files. The default lives in
         the app's Application Support container.
     - Side effects: none at construction time; directories are created lazily on first write.
     - Failure modes: This initializer cannot fail.
     */
    public init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
    }

    /**
     Returns whether a preserved database currently exists for a category.

     - Parameter category: Android backup category to inspect.
     - Returns: `true` when a preserved database file exists.
     - Side effects: none.
     - Failure modes: Unknown categories return `false`.
     */
    public func hasDatabase(for category: AndroidDatabaseBackupCategory) -> Bool {
        guard Self.preservedCategories.contains(category) else {
            return false
        }
        return fileManager.fileExists(atPath: databaseURL(for: category).path)
    }

    /**
     Stores one extracted Android database as preserved Android-owned state.

     - Parameters:
       - sourceURL: Validated extracted SQLite database selected from a backup archive.
       - category: Android backup category represented by `sourceURL`.
     - Returns: Preserved database metadata after replacement.
     - Side effects:
       - creates the preservation directory when needed
       - atomically replaces any existing preserved database for the category
     - Failure modes:
       - throws when the category is not explicitly preservable
       - throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when the source is not readable
         as SQLite or is newer than the category version this build supports
       - rethrows file-system failures from copy, remove, and move operations
     */
    @discardableResult
    public func restoreDatabase(
        from sourceURL: URL,
        category: AndroidDatabaseBackupCategory
    ) throws -> AndroidDatabaseBackupPreservedDatabaseReport {
        try requirePreservable(category)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let temporaryURL = rootDirectory.appendingPathComponent("\(UUID().uuidString)-\(category.databaseFileName ?? "database")")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        let report = try validateDatabase(at: temporaryURL, category: category)
        let destinationURL = databaseURL(for: category)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return report
    }

    /**
     Copies a preserved Android database to a caller-owned export location.

     - Parameters:
       - category: Android backup category to materialize.
       - destinationURL: Export database URL to create.
     - Returns: Preserved database metadata when the source exists, otherwise `nil`.
     - Side effects: Copies the preserved database file to `destinationURL`.
     - Failure modes:
       - throws when the category is not preservable
       - throws if the preserved database is malformed or too new for this build
       - rethrows file-system copy failures
     */
    @discardableResult
    public func copyDatabase(
        for category: AndroidDatabaseBackupCategory,
        to destinationURL: URL
    ) throws -> AndroidDatabaseBackupPreservedDatabaseReport? {
        try requirePreservable(category)
        let sourceURL = databaseURL(for: category)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        let report = try validateDatabase(at: sourceURL, category: category)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return report
    }

    /**
     Removes a preserved Android-owned database.

     - Parameter category: Android backup category to clear.
     - Side effects: Deletes the preserved database file if it exists.
     - Failure modes: Throws when the category is not preservable or when file deletion fails.
     */
    public func removeDatabase(for category: AndroidDatabaseBackupCategory) throws {
        try requirePreservable(category)
        let url = databaseURL(for: category)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    /**
     Reads metadata for a preserved Android-owned database.

     - Parameter category: Android backup category to inspect.
     - Returns: Metadata when the preserved file exists, otherwise `nil`.
     - Side effects: Opens the preserved SQLite file read-only.
     - Failure modes: Throws when the preserved database file is malformed or too new.
     */
    public func report(for category: AndroidDatabaseBackupCategory) throws -> AndroidDatabaseBackupPreservedDatabaseReport? {
        try requirePreservable(category)
        let url = databaseURL(for: category)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try validateDatabase(at: url, category: category)
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("AndroidDatabaseBackup", isDirectory: true)
            .appendingPathComponent("PreservedDatabases", isDirectory: true)
    }

    private func databaseURL(for category: AndroidDatabaseBackupCategory) -> URL {
        rootDirectory.appendingPathComponent(category.databaseFileName ?? category.rawValue)
    }

    private func requirePreservable(_ category: AndroidDatabaseBackupCategory) throws {
        guard Self.preservedCategories.contains(category) else {
            throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                category,
                "Android \(category.displayName) cannot be preserved as an Android-owned database."
            )
        }
    }

    private func validateDatabase(
        at url: URL,
        category: AndroidDatabaseBackupCategory
    ) throws -> AndroidDatabaseBackupPreservedDatabaseReport {
        guard let fileName = category.databaseFileName else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(category.rawValue)
        }
        let version = try sqliteUserVersion(at: url, fileName: fileName)
        guard version <= category.supportedDatabaseVersion else {
            throw AndroidDatabaseBackupError.unsupportedSelectedSection(
                category,
                "Requires database version \(version); this app supports up to \(category.supportedDatabaseVersion)."
            )
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return AndroidDatabaseBackupPreservedDatabaseReport(
            category: category,
            byteCount: byteCount,
            databaseVersion: version
        )
    }

    private func sqliteUserVersion(at url: URL, fileName: String) throws -> Int {
        try AndroidDatabaseBackupSQLite.withDatabase(at: url, flags: SQLITE_OPEN_READONLY) { database in
            let statement = try AndroidDatabaseBackupSQLite.prepare(
                "PRAGMA user_version;",
                on: database,
                fileName: fileName
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }
}

/**
 Metadata emitted when an Android-owned database is preserved or exported.

 The report intentionally avoids row counts because this store does not interpret category semantics.
 */
public struct AndroidDatabaseBackupPreservedDatabaseReport: Sendable, Equatable {
    /// Android backup category represented by the preserved database.
    public let category: AndroidDatabaseBackupCategory

    /// Preserved SQLite file size in bytes.
    public let byteCount: Int64

    /// SQLite `PRAGMA user_version` validated for this category.
    public let databaseVersion: Int

    /**
     Creates preserved database metadata.

     - Parameters:
       - category: Android backup category represented by the preserved database.
       - byteCount: Preserved SQLite file size in bytes.
       - databaseVersion: SQLite `PRAGMA user_version` validated for this category.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: AndroidDatabaseBackupCategory, byteCount: Int64, databaseVersion: Int) {
        self.category = category
        self.byteCount = byteCount
        self.databaseVersion = databaseVersion
    }
}
