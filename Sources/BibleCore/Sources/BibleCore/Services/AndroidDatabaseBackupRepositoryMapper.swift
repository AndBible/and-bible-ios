// AndroidDatabaseBackupRepositoryMapper.swift -- Android repositories.sqlite3 backup mapper

import Foundation
import SQLite3
import SwiftData
import SwordKit

/**
 Summary for applying Android's `repositories.sqlite3` database.
 */
public struct AndroidDatabaseBackupRepositoryReport: Sendable, Equatable {
    /// Number of custom repositories restored into the iOS repository-source configuration.
    public let restoredRepositoryCount: Int
}

/**
 Maps Android custom repository rows into iOS Downloads source configuration.

 Android treats `repositories.sqlite3` as restore-only. iOS preserves that observable behavior by
 replacing every custom repository source through `RepositorySourceManager`, while deleting legacy
 SwiftData `Repository` rows only after the canonical source configuration has been persisted.
 */
enum AndroidDatabaseBackupRepositoryMapper {
    private struct CustomRepositoryRow {
        let name: String
        let description: String
        let type: String
        let host: String
        let catalogDirectory: String
        let packageDirectory: String
        let manifestURL: String?
    }

    /**
     Restores Android custom repositories into the iOS repository source manager.

     - Parameters:
       - databaseURL: Extracted Android `repositories.sqlite3` file.
       - repositorySourceManager: Downloads source manager that owns source persistence.
       - modelContext: SwiftData context containing legacy iOS repository rows.
     - Returns: Count of restored custom repository sources.
     - Side effects:
       - replaces all custom repository source configuration
       - deletes legacy SwiftData `Repository` rows after source persistence succeeds
     - Failure modes: Throws when the Android database is malformed or contains unsupported source
       rows that iOS Downloads cannot consume.
     */
    static func restore(
        from databaseURL: URL,
        repositorySourceManager: RepositorySourceManager,
        modelContext: ModelContext
    ) throws -> AndroidDatabaseBackupRepositoryReport {
        let rows = try readCustomRepositories(from: databaseURL)
        let registrations = try rows.map(registration)
        try repositorySourceManager.replaceCustomSources(with: registrations)
        try deleteLegacyRepositories(modelContext: modelContext)
        return AndroidDatabaseBackupRepositoryReport(restoredRepositoryCount: registrations.count)
    }

    /**
     Writes an Android-compatible `repositories.sqlite3` database from current custom sources.

     - Parameters:
       - databaseURL: Destination SQLite URL.
       - repositorySourceManager: Downloads source manager to snapshot.
     - Returns: Number of custom repository rows written.
     - Side effects: Creates or replaces the SQLite database file.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       schema creation or row insertion.
     */
    @discardableResult
    static func writeDatabase(
        at databaseURL: URL,
        repositorySourceManager: RepositorySourceManager
    ) throws -> Int {
        let rows = repositorySourceManager.loadSources()
            .filter { !repositorySourceManager.isDefaultSource($0) }
            .map { Self.row(from: $0) }
        try? FileManager.default.removeItem(at: databaseURL)
        return try AndroidDatabaseBackupSQLite.withDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            let fileName = databaseURL.lastPathComponent
            try AndroidDatabaseBackupSQLite.execute(
                """
                CREATE TABLE CustomRepository (
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    type TEXT NOT NULL,
                    host TEXT NOT NULL,
                    catalogDirectory TEXT NOT NULL,
                    packageDirectory TEXT NOT NULL,
                    manifestUrl TEXT
                );
                CREATE UNIQUE INDEX index_CustomRepository_name ON CustomRepository (name);
                CREATE TABLE SwordDocumentInfo (
                    initials TEXT NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    abbreviation TEXT NOT NULL,
                    language TEXT NOT NULL,
                    repository TEXT NOT NULL,
                    cipherKey TEXT
                );
                PRAGMA user_version = 1;
                """,
                on: database,
                fileName: fileName
            )
            for row in rows {
                try insert(row, into: database, fileName: fileName)
            }
            return rows.count
        }
    }

    private static func readCustomRepositories(from databaseURL: URL) throws -> [CustomRepositoryRow] {
        try AndroidDatabaseBackupSQLite.withDatabase(at: databaseURL) { database in
            let fileName = databaseURL.lastPathComponent
            let statement = try AndroidDatabaseBackupSQLite.prepare(
                """
                SELECT name, description, type, host, catalogDirectory, packageDirectory, manifestUrl
                FROM CustomRepository
                ORDER BY id;
                """,
                on: database,
                fileName: fileName
            )
            defer { sqlite3_finalize(statement) }

            var rows: [CustomRepositoryRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE {
                    break
                }
                guard result == SQLITE_ROW else {
                    throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
                }
                rows.append(
                    CustomRepositoryRow(
                        name: AndroidDatabaseBackupSQLite.text(statement, column: 0),
                        description: AndroidDatabaseBackupSQLite.text(statement, column: 1),
                        type: AndroidDatabaseBackupSQLite.text(statement, column: 2),
                        host: AndroidDatabaseBackupSQLite.text(statement, column: 3),
                        catalogDirectory: AndroidDatabaseBackupSQLite.text(statement, column: 4),
                        packageDirectory: AndroidDatabaseBackupSQLite.text(statement, column: 5),
                        manifestURL: AndroidDatabaseBackupSQLite.optionalText(statement, column: 6)
                    )
                )
            }
            return rows
        }
    }

    private static func registration(from row: CustomRepositoryRow) throws -> RepositorySourceRegistration {
        let sourceURL = try httpsURL(host: row.host, path: row.catalogDirectory)
        let manifestURL = preferredManifestURL(from: row.manifestURL, fallback: sourceURL)
        switch row.type {
        case SourceConfig.swordHTTPSRepositoryType:
            let source = SourceConfig(
                name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: "HTTP",
                host: row.host.trimmingCharacters(in: .whitespacesAndNewlines),
                catalogPath: normalizedPath(row.catalogDirectory),
                repositoryType: row.type,
                description: row.description,
                packageDirectory: row.packageDirectory.isEmpty ? nil : row.packageDirectory,
                manifestURL: manifestURL,
                sourceURL: sourceURL
            )
            return RepositorySourceRegistration(
                source: source,
                description: row.description,
                packageDirectory: row.packageDirectory,
                manifestURL: manifestURL,
                sourceURL: sourceURL,
                type: row.type
            )
        case SourceConfig.myBibleHTTPSRepositoryType:
            let source = SourceConfig(
                name: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                type: "HTTP",
                host: row.host.trimmingCharacters(in: .whitespacesAndNewlines),
                catalogPath: normalizedPath(manifestURL.path),
                repositoryType: row.type,
                description: row.description,
                packageDirectory: nil,
                manifestURL: manifestURL,
                sourceURL: manifestURL
            )
            return RepositorySourceRegistration(
                source: source,
                description: row.description,
                packageDirectory: "",
                manifestURL: manifestURL,
                sourceURL: manifestURL,
                type: row.type
            )
        default:
            throw RepositorySourceManagementError.unsupportedRepositoryType(row.type)
        }
    }

    private static func row(from source: SourceConfig) -> CustomRepositoryRow {
        let repositoryType = source.repositoryType
        return CustomRepositoryRow(
            name: source.name,
            description: source.description ?? source.sourceURL?.absoluteString ?? source.name,
            type: repositoryType,
            host: source.host,
            catalogDirectory: source.catalogPath,
            packageDirectory: source.packageDirectory ?? "",
            manifestURL: source.manifestURL?.absoluteString
        )
    }

    private static func insert(
        _ row: CustomRepositoryRow,
        into database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            INSERT INTO CustomRepository (
                name,
                description,
                type,
                host,
                catalogDirectory,
                packageDirectory,
                manifestUrl
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }

        AndroidDatabaseBackupSQLite.bindText(row.name, to: statement, index: 1)
        AndroidDatabaseBackupSQLite.bindText(row.description, to: statement, index: 2)
        AndroidDatabaseBackupSQLite.bindText(row.type, to: statement, index: 3)
        AndroidDatabaseBackupSQLite.bindText(row.host, to: statement, index: 4)
        AndroidDatabaseBackupSQLite.bindText(row.catalogDirectory, to: statement, index: 5)
        AndroidDatabaseBackupSQLite.bindText(row.packageDirectory, to: statement, index: 6)
        AndroidDatabaseBackupSQLite.bindOptionalText(row.manifestURL, to: statement, index: 7)
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    private static func deleteLegacyRepositories(modelContext: ModelContext) throws {
        for repository in try modelContext.fetch(FetchDescriptor<Repository>()) {
            modelContext.delete(repository)
        }
        try modelContext.save()
    }

    private static func preferredManifestURL(from rawValue: String?, fallback: URL) -> URL {
        guard let rawValue,
              let candidate = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              candidate.scheme?.lowercased() == "https",
              candidate.host?.isEmpty == false else {
            return fallback
        }
        return candidate
    }

    private static func httpsURL(host: String, path: String) throws -> URL {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = normalizedPath(path)
        guard let url = URL(string: "https://\(trimmedHost)\(trimmedPath)"),
              url.host?.isEmpty == false else {
            throw RepositorySourceManagementError.invalidURL("https://\(trimmedHost)\(trimmedPath)")
        }
        return url
    }

    private static func normalizedPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }
}
