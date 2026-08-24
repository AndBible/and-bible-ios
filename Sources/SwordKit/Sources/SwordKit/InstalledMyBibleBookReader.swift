// InstalledMyBibleBookReader.swift -- Android-compatible installed MyBible metadata projection

import Foundation
import SQLite3

/**
 One installed MyBible payload projected into the fields required by shared book inventory.

 Android constructs installed MyBible book identity and display metadata from the opened database,
 not from the repository manifest row that downloaded it. This immutable value keeps that payload-
 owned `ModuleInfo` beside the unsanitized Android abbreviation and exact file owner so
 `SwordManager` can apply JSword ordering and collision admission without reopening the database.

 Values are produced synchronously in deterministic raw UTF-16 payload-path order. Construction has
 no side effects after the reader closes its read-only SQLite handle. Malformed payloads never
 produce a registration.
 */
struct InstalledMyBibleBookRegistration: Sendable {
    /// Metadata whose initials, description, language, and category belong to the opened payload.
    let info: ModuleInfo

    /// Unsanitized payload basename segment before the first dot, matching Android `Abbreviation`.
    let abbreviation: String

    /// Sidecar module directory that owns the database and repository metadata.
    let moduleDirectoryURL: URL

    /// Exact immediate database file that owns the projected identity and display metadata.
    let databaseURL: URL
}

/**
 Reads Android-compatible installed-book metadata from one MyBible sidecar module directory.

 Android's `SqliteVerseBackendState` derives identity from the actual database filename, reads
 `description`, `language`, and feature evidence from the database, classifies the payload by exact
 table names, and emits the generated version `0.0`. The sidecar remains authoritative only for
 repository/install provenance. This reader deliberately performs no registration or collision
 handling; it emits ordered payload-owned values for `SwordManager` to admit against the combined
 installed registry.

 Every SQLite handle is opened read-only, used on the calling thread, and closed before the call
 returns. The type owns no shared mutable state and is safe to call concurrently for different or
 identical directories. Filesystem or SQLite failures skip only the affected payload.
 */
enum InstalledMyBibleBookReader {
    /**
     Metadata read from Android's `info` values, content evidence, and exact table classification.

     This intermediate value prevents sidecar fields from accidentally replacing database-owned
     metadata before the final `ModuleInfo` is constructed. It has no behavior or side effects after
     initialization and cannot represent an unclassified schema.
     */
    private struct DatabaseMetadata {
        /// Exact database `info.description`, or Android's empty fallback when the row is absent.
        let description: String

        /// Exact database `info.language`, or Android's `en` fallback when the row is absent.
        let language: String

        /// Category selected by exact table-name priority: verses, commentaries, then dictionary.
        let category: ModuleCategory

        /// Independent Strong's-definition, Strong's-number, and Words-of-Christ capabilities.
        let features: ModuleFeatures
    }

    /**
     Reads every immediate SQLite/MyBible payload owned by one decoded sidecar directory.

     - Parameters:
       - moduleDirectory: Directory containing `module.json` and immediate extracted payload files.
         Nested files are intentionally ignored because iOS publishes package payloads flat.
       - sidecar: Decoded repository metadata used only for version and repository attribution.
     - Returns: Successfully opened registrations ordered by exact payload path using Java raw UTF-16
       comparison. Canonically equivalent but Java-distinct filenames remain separately ordered.
     - Side effects: Enumerates one directory and opens/closes each candidate SQLite database in
       read-only mode. It does not create, mutate, move, or delete files.
     - Failure modes: Missing/unreadable directories return an empty array. Non-files, unsupported
       extensions, databases that cannot open, missing `info`, query failures, and schemas without a
       recognized content table are skipped independently.
     - Important: The method is synchronous and owns each SQLite handle only on the calling thread;
       no handle or prepared statement escapes the call.
     */
    static func registrations(
        in moduleDirectory: URL,
        sidecar: InstalledMyBibleModule
    ) -> [InstalledMyBibleBookRegistration] {
        immediatePayloadURLs(in: moduleDirectory).compactMap { payloadURL in
            registration(for: payloadURL, sidecar: sidecar)
        }
    }

    /**
     Projects one readable payload into Android-derived installed metadata.

     - Parameters:
       - payloadURL: Immediate SQLite/MyBible file whose basename and database own the book metadata.
       - sidecar: Repository metadata supplying source attribution only.
     - Returns: A payload-owned registration, or `nil` when the file cannot prove the Android schema
       and metadata contract.
     - Side effects: Opens `payloadURL` with `SQLITE_OPEN_READONLY`, executes metadata-only queries,
       finalizes all statements, and closes the handle before returning.
     - Failure modes: Open, schema, or `info` query failures return `nil`; no partial registration is
       emitted. Missing description/language rows use Android's `""`/`"en"` defaults.
     - Important: SQLite access is confined to this synchronous scope; no database pointer escapes.
     */
    private static func registration(
        for payloadURL: URL,
        sidecar: InstalledMyBibleModule
    ) -> InstalledMyBibleBookRegistration? {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            payloadURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }

        guard let metadata = databaseMetadata(from: database) else { return nil }
        let filenameIdentity = MyBibleAndroidFilenameIdentity(
            fileName: payloadURL.lastPathComponent
        )
        let initials = filenameIdentity.initials
        let driver = moduleDriver(for: metadata.category)
        let moduleInfo = ModuleInfo(
            name: initials,
            description: metadata.description,
            category: metadata.category,
            language: metadata.language,
            moduleDriver: driver,
            version: "0.0",
            features: metadata.features,
            aboutMetadata: ModuleAboutMetadata(
                versification: "KJVA",
                osisId: initials,
                repository: sidecar.sourceName
            )
        )
        return InstalledMyBibleBookRegistration(
            info: moduleInfo,
            abbreviation: filenameIdentity.abbreviation,
            moduleDirectoryURL: payloadURL.deletingLastPathComponent(),
            databaseURL: payloadURL
        )
    }

    /**
     Reads Android-owned description, language, category, version-independent feature evidence.

     - Parameter database: Open read-only SQLite handle valid for the duration of this call.
     - Returns: Complete payload metadata when `info` is queryable and a recognized content table is
       present; otherwise `nil`. Feature flags stay independent of category except that Android only
       detects Words-of-Christ for Bible schemas.
     - Side effects: Prepares, steps, and finalizes read-only SQLite statements.
     - Failure modes: A missing/malformed `info` table, SQLite step error, or schema without `verses`,
       `commentaries`, or `dictionary` returns `nil`. Missing individual info rows use Android's
       defaults.
     - Note: Exact table names are tested in Android priority order, independent of SQLite catalog
       enumeration order.
     */
    private static func databaseMetadata(from database: OpaquePointer) -> DatabaseMetadata? {
        guard let description = infoValue(
            named: "description",
            defaultValue: "",
            database: database
        ), let language = infoValue(
            named: "language",
            defaultValue: "en",
            database: database
        ), let strongsDefinitions = infoValue(
            named: "is_strong",
            defaultValue: "",
            database: database
        ), let strongsNumbers = infoValue(
            named: "strong_numbers",
            defaultValue: "",
            database: database
        ), let tableNames = tableNames(in: database),
           let category = moduleCategory(for: tableNames) else {
            return nil
        }
        var features: ModuleFeatures = []
        if strongsDefinitions == "true" {
            features.formUnion([.greekDef, .hebrewDef])
        }
        if strongsNumbers == "true" {
            features.insert(.strongsNumbers)
        }
        if wordsOfChristAvailable(in: database, category: category) {
            features.insert(.redLetterWords)
        }
        return DatabaseMetadata(
            description: description,
            language: language,
            category: category,
            features: features
        )
    }

    /**
     Detects Android's Words-of-Christ feature from exact info aliases or verse markup.

     - Parameters:
       - database: Open read-only SQLite handle.
       - category: Payload category already proven from exact table names.
     - Returns: `true` only for a Bible with a truthy Android metadata alias or at least one verse
       containing a case-insensitive `<J>` marker.
     - Side effects: Prepares, steps, and finalizes at most two read-only SQLite statements.
     - Failure modes: Non-Bible categories and any prepare/step failure return `false`, matching
       Android's caught `SQLiteException` path without rejecting otherwise readable metadata.
     */
    private static func wordsOfChristAvailable(
        in database: OpaquePointer,
        category: ModuleCategory
    ) -> Bool {
        guard category == .bible else { return false }

        let flagSQL = """
        SELECT value FROM info
        WHERE name IN ('is_words_of_christ', 'words_of_christ', 'is_red_letter', 'red_letter')
        """
        var flagStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, flagSQL, -1, &flagStatement, nil) == SQLITE_OK,
              let flagStatement else {
            return false
        }
        var flagQuerySucceeded = false
        while true {
            switch sqlite3_step(flagStatement) {
            case SQLITE_ROW:
                let value = sqlite3_column_type(flagStatement, 0) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(flagStatement, 0).map { String(cString: $0) }
                if parseMyBibleBoolean(value) {
                    sqlite3_finalize(flagStatement)
                    return true
                }
            case SQLITE_DONE:
                flagQuerySucceeded = true
                sqlite3_finalize(flagStatement)
                break
            default:
                sqlite3_finalize(flagStatement)
                return false
            }
            if flagQuerySucceeded { break }
        }

        let verseSQL = "SELECT 1 FROM verses WHERE instr(lower(text), '<j>') > 0 LIMIT 1"
        var verseStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, verseSQL, -1, &verseStatement, nil) == SQLITE_OK,
              let verseStatement else {
            return false
        }
        defer { sqlite3_finalize(verseStatement) }
        return sqlite3_step(verseStatement) == SQLITE_ROW
    }

    /**
     Parses the boolean forms Android accepts for Words-of-Christ aliases.

     - Parameter value: Nullable SQLite text from one supported info row.
     - Returns: `true` for case-insensitive `true` or exact `1`; `false` otherwise.
     - Side effects: None.
     - Failure modes: None; missing and unsupported values are false.
     */
    private static func parseMyBibleBoolean(_ value: String?) -> Bool {
        value?.caseInsensitiveCompare("true") == .orderedSame || value == "1"
    }

    /**
     Reads the first exact-name value from Android's MyBible `info` table.

     - Parameters:
       - name: Trusted exact metadata key for description, language, or a feature flag.
       - defaultValue: Android fallback returned for a missing row or SQL `NULL` value.
       - database: Open read-only SQLite handle.
     - Returns: Exact UTF-8 text, the supplied fallback for no value, or `nil` when preparation or
       stepping fails.
     - Side effects: Prepares, steps once, and finalizes one read-only statement.
     - Failure modes: Missing `info`, malformed SQLite, and non-row/non-done step results return nil.
     */
    private static func infoValue(
        named name: String,
        defaultValue: String,
        database: OpaquePointer
    ) -> String? {
        let sql = "SELECT value FROM info WHERE name = '\(name)'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, 0) else {
                return defaultValue
            }
            return String(cString: value)
        case SQLITE_DONE:
            return defaultValue
        default:
            return nil
        }
    }

    /**
     Reads exact user-table names from SQLite's schema catalog.

     - Parameter database: Open read-only SQLite handle.
     - Returns: Java-exact UTF-16 identities for every non-internal table, or `nil` on query failure.
     - Side effects: Prepares, fully steps, and finalizes one read-only schema statement.
     - Failure modes: Prepare/step failures or null table names return `nil`; an empty valid schema
       returns an empty set for the caller to reject as unclassified.
     */
    private static func tableNames(
        in database: OpaquePointer
    ) -> Set<SwordJavaExactStringIdentity>? {
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<SwordJavaExactStringIdentity> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(statement, 0) else { return nil }
                names.insert(SwordJavaExactStringIdentity(String(cString: value)))
            case SQLITE_DONE:
                return names
            default:
                return nil
            }
        }
    }

    /**
     Applies Android MyBible content-table priority to exact SQLite table identities.

     - Parameter tableNames: Exact table identities read from `sqlite_master`.
     - Returns: Bible for `verses`, otherwise commentary for `commentaries`, otherwise dictionary for
       `dictionary`; `nil` when no supported content table exists.
     - Side effects: None.
     - Failure modes: None; unsupported schemas are represented by `nil`.
     */
    private static func moduleCategory(
        for tableNames: Set<SwordJavaExactStringIdentity>
    ) -> ModuleCategory? {
        if tableNames.contains(SwordJavaExactStringIdentity("verses")) { return .bible }
        if tableNames.contains(SwordJavaExactStringIdentity("commentaries")) { return .commentary }
        if tableNames.contains(SwordJavaExactStringIdentity("dictionary")) { return .dictionary }
        return nil
    }

    /**
     Maps an admitted MyBible category to iOS's registered SQLite-backed driver identity.

     - Parameter category: Category proven from the payload's exact table names.
     - Returns: MyBible Bible, commentary, or dictionary driver name.
     - Side effects: None.
     - Failure modes: None; callers provide only one of the three admitted categories.
     */
    private static func moduleDriver(for category: ModuleCategory) -> String {
        switch category {
        case .bible:
            return "MyBibleBible"
        case .commentary:
            return "MyBibleCommentary"
        case .dictionary:
            return "MyBibleDictionary"
        default:
            preconditionFailure("Unclassified MyBible category reached driver projection")
        }
    }

    /**
     Enumerates immediate candidate payload files in deterministic Java raw-string order.

     - Parameter moduleDirectory: Sidecar directory whose immediate files are inspected.
     - Returns: Readable regular `.SQLite3`/`.mybible` candidates sorted by exact UTF-16 path.
     - Side effects: Reads directory and file metadata.
     - Failure modes: Directory enumeration failure returns an empty array; unreadable/non-regular or
       unsupported files are omitted.
     - Note: Hidden payloads are retained because Android's filesystem walk does not exclude them.
     */
    private static func immediatePayloadURLs(in moduleDirectory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: moduleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && fileManager.isReadableFile(atPath: url.path)
                && isMyBiblePayloadFileName(url.lastPathComponent)
        }.sorted { rawUTF16Compare($0.path, $1.path) < 0 }
    }

    /**
     Tests the two immediate payload extensions accepted by iOS MyBible package storage.

     - Parameter fileName: Exact final path component.
     - Returns: True for a Java case-insensitive `.sqlite3` or `.mybible` suffix.
     - Side effects: Loads the pinned Android character table through case-insensitive comparison.
     - Failure modes: A missing/corrupt compatibility table traps through the shared identity helper;
       short names return false.
     */
    private static func isMyBiblePayloadFileName(_ fileName: String) -> Bool {
        hasJavaCaseInsensitiveSuffix(fileName, suffix: ".sqlite3")
            || hasJavaCaseInsensitiveSuffix(fileName, suffix: ".mybible")
    }

    /**
     Compares one filename suffix with Android `String.equalsIgnoreCase` UTF-16 semantics.

     - Parameters:
       - value: Exact filename.
       - suffix: ASCII extension including its leading dot.
     - Returns: True when the final UTF-16 units equal the suffix under Android's non-expanding
       per-`char` case comparison.
     - Side effects: Loads the pinned Android character table through the shared comparator.
     - Failure modes: Values shorter than the suffix return false; a missing compatibility resource
       traps rather than silently using host Unicode behavior.
     */
    private static func hasJavaCaseInsensitiveSuffix(_ value: String, suffix: String) -> Bool {
        let valueUnits = Array(value.utf16)
        let suffixUnits = Array(suffix.utf16)
        guard valueUnits.count >= suffixUnits.count else { return false }
        let candidate = String(decoding: valueUnits.suffix(suffixUnits.count), as: UTF16.self)
        return SwordJavaStringIdentity.equalsIgnoreCase(candidate, suffix)
    }

    /**
     Compares exact strings with Java `String.compareTo` raw UTF-16 ordering.

     - Parameters:
       - lhs: First exact path string.
       - rhs: Second exact path string.
     - Returns: Difference at the first unequal UTF-16 unit, otherwise the length difference.
     - Side effects: None.
     - Failure modes: None; Swift exposes both strings as valid UTF-16 sequences.
     */
    private static func rawUTF16Compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.utf16
        let right = rhs.utf16
        for (leftUnit, rightUnit) in zip(left, right) where leftUnit != rightUnit {
            return Int(leftUnit) - Int(rightUnit)
        }
        return left.count - right.count
    }
}
