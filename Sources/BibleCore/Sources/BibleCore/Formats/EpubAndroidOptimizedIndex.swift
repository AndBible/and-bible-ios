// EpubAndroidOptimizedIndex.swift -- Android Room/gzip EPUB generation import

import Foundation
import SQLite3

/**
 Imports Android's installed optimized EPUB representation into the native iOS EPUB index.

 Android stores immutable-looking XHTML fragments under `optimized/`, but their meaning is carried
 by a Room database at the display-name root. The importer treats the database, fragment files, OPF,
 and optional search database as one exact unit and rejects any cross-file mismatch before commit.
 */
enum EpubAndroidOptimizedIndexImporter {
    /// Android optimizer versions whose fragment and Room schemas are understood by this importer.
    private static let supportedOptimizerVersions = 1...2

    /** Resolved Android-generated files belonging to one display-name directory. */
    private struct Artifacts {
        /// Directory containing padded `<fragment id>.xhtml.gz` members and `version.txt`.
        let optimizedDirectoryURL: URL

        /// Gzip-compressed Room database selected by Android's current/fallback naming order.
        let databaseArchiveURL: URL

        /// Optional exact-name Android FTS database.
        let searchDatabaseURL: URL?
    }

    /** One validated Room `EpubFragment` row and its transformed native XHTML. */
    struct FragmentRecord {
        /// Android numeric general-book key retained as the iOS `content.id`.
        let id: Int

        /// OPF manifest identifier owning this fragment.
        let originalID: String

        /// Inclusive Android BVA ordinal range.
        let ordinalRange: ClosedRange<Int>

        /// Sanitized native fragment and link targets.
        let transformed: EpubAndroidOptimizedTransformedFragment
    }

    /** One validated Room `EpubHtmlToFrag` row projected into iOS anchor-map columns. */
    struct AnchorMapping {
        /// OPF manifest identifier.
        let originalID: String

        /// Exact XHTML id, or an empty string for the document base mapping.
        let htmlID: String

        /// Android fragment key that owns this target.
        let fragmentID: Int
    }

    /** One validated Room `StyleSheet` row resolved to a package-contained canonical path. */
    struct StyleRecord {
        /// OPF manifest identifier whose fragments apply the stylesheet.
        let originalID: String

        /// Canonical package-relative CSS path.
        let path: String
    }

    /**
     Builds a current native index from an Android tree whose original spine files are unavailable.

     - Parameters:
       - androidRootURL: Exact source `epub/<displayName>/` directory retaining optimization files.
       - packageRootURL: Copied package-only staging root.
       - indexURL: Destination native SQLite index inside generation staging.
       - package: Parsed OPF/navigation model from `packageRootURL`.
       - resourceIdentity: Android initials plus the new immutable generation token.
       - sourceFileName: Exact Android display-name directory component.
     - Side effects: Reads gzip and SQLite files, writes one temporary Room database beside
       `indexURL`, creates the native index, and removes the temporary database before returning.
     - Throws: `EpubError` or file-system errors for corruption, unsupported versions, unsafe paths,
       schema drift, missing fragments, mapping mismatches, or SQLite failures.
     */
    static func buildIndex(
        androidRootURL: URL,
        packageRootURL: URL,
        indexURL: URL,
        package: EpubPackageDocument,
        resourceIdentity: EpubResourceIdentity,
        sourceFileName: String
    ) throws {
        let fileManager = FileManager.default
        let artifacts = try resolveArtifacts(
            androidRootURL: androidRootURL,
            initials: resourceIdentity.bookInitials,
            fileManager: fileManager
        )
        try validateOptimizerVersion(in: artifacts.optimizedDirectoryURL)

        let temporaryDatabaseURL = indexURL.deletingLastPathComponent().appendingPathComponent(
            ".android-optimized-\(UUID().uuidString).sqlite3"
        )
        defer { try? fileManager.removeItem(at: temporaryDatabaseURL) }
        try EpubAndroidGzipDecoder.inflate(
            sourceURL: artifacts.databaseArchiveURL,
            destinationURL: temporaryDatabaseURL,
            maximumOutputBytes: EpubReader.maximumArchiveEntryByteCount
        )

        var androidDatabase: OpaquePointer?
        guard sqlite3_open_v2(
            temporaryDatabaseURL.path,
            &androidDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let androidDatabase else {
            sqlite3_close(androidDatabase)
            throw EpubError.invalidEpub("Android optimized EPUB database is not readable SQLite")
        }
        defer { sqlite3_close(androidDatabase) }
        try validateRoomDatabase(androidDatabase)

        let fragments = try loadFragments(
            database: androidDatabase,
            artifacts: artifacts,
            package: package,
            packageRootURL: packageRootURL,
            resourceIdentity: resourceIdentity,
            fileManager: fileManager
        )
        let mappings = try loadAnchorMappings(database: androidDatabase, fragments: fragments)
        try validateInternalLinks(fragments: fragments, mappings: mappings)
        let styles = try loadStyles(
            database: androidDatabase,
            fragments: fragments,
            package: package,
            packageRootURL: packageRootURL
        )
        if let searchDatabaseURL = artifacts.searchDatabaseURL {
            try validateSearchDatabase(at: searchDatabaseURL, fragments: fragments)
        }
        try writeNativeIndex(
            at: indexURL,
            package: package,
            fragments: fragments,
            mappings: mappings,
            styles: styles,
            resourceIdentity: resourceIdentity,
            sourceFileName: sourceFileName
        )
    }

    /**
     Resolves only the database filenames Android would use for the supplied module initials.

     - Parameters:
       - androidRootURL: Display-name directory containing Android optimization state.
       - initials: Exact `Epub-<sanitized displayName>` identity.
       - fileManager: File-system implementation used for root inspection.
     - Returns: Exact fragment directory, one supported database archive, and optional search DB.
     - Side effects: Lists root files and reads file metadata.
     - Throws: `EpubError.invalidEpub` for missing, duplicate, symbolic-link, or identity-mismatched
       database paths. A renamed database is never accepted by wildcard.
     */
    private static func resolveArtifacts(
        androidRootURL: URL,
        initials: String,
        fileManager: FileManager
    ) throws -> Artifacts {
        let optimizedDirectoryURL = androidRootURL.appendingPathComponent("optimized", isDirectory: true)
        let optimizedValues = try optimizedDirectoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard optimizedValues.isDirectory == true, optimizedValues.isSymbolicLink != true else {
            throw EpubError.invalidEpub("Android optimized EPUB fragment directory is missing")
        }

        let genericDatabaseName = "optimized.sqlite3.gz"
        let identityDatabaseName = "epub-\(initials).sqlite3.gz"
        let expectedSearchName = "epub-\(initials)-search.sqlite3"
        let rootChildren = try fileManager.contentsOfDirectory(
            at: androidRootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []
        )
        var databaseCandidates: [URL] = []
        var searchDatabaseURL: URL?
        for child in rootChildren {
            let name = child.lastPathComponent
            let values = try child.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            if name == genericDatabaseName || name == identityDatabaseName {
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      UInt64(max(0, values.fileSize ?? 0))
                        <= EpubReader.maximumArchiveEntryByteCount else {
                    throw EpubError.invalidEpub("Android optimized EPUB database is not a regular file")
                }
                databaseCandidates.append(child)
                continue
            }
            if name.hasPrefix("epub-") && name.hasSuffix(".sqlite3.gz") {
                throw EpubError.invalidEpub(
                    "Android optimized EPUB database filename does not match \(initials)"
                )
            }
            if name == expectedSearchName {
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      UInt64(max(0, values.fileSize ?? 0))
                        <= EpubReader.maximumArchiveEntryByteCount else {
                    throw EpubError.invalidEpub("Android EPUB search database is not a regular file")
                }
                searchDatabaseURL = child
                continue
            }
            if name.hasPrefix("epub-") && name.contains("-search.sqlite3") {
                throw EpubError.invalidEpub(
                    "Android EPUB search database filename does not match \(initials)"
                )
            }
        }
        guard databaseCandidates.count == 1, let databaseArchiveURL = databaseCandidates.first else {
            let reason = databaseCandidates.isEmpty ? "is missing" : "is ambiguous"
            throw EpubError.invalidEpub("Android optimized EPUB database \(reason)")
        }
        return Artifacts(
            optimizedDirectoryURL: optimizedDirectoryURL,
            databaseArchiveURL: databaseArchiveURL,
            searchDatabaseURL: searchDatabaseURL
        )
    }

    /**
     Validates Android's optimizer-version marker before interpreting fragment XML.

     - Parameter optimizedDirectoryURL: Android `optimized/` directory.
     - Side effects: Reads at most 32 bytes from `version.txt`.
     - Throws: `EpubError.invalidEpub` when the marker is absent, oversized, malformed, or newer than
       the fragment contract implemented here.
     */
    private static func validateOptimizerVersion(in optimizedDirectoryURL: URL) throws {
        let versionURL = optimizedDirectoryURL.appendingPathComponent("version.txt")
        let values = try versionURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 32 else {
            throw EpubError.invalidEpub("Unsupported Android EPUB optimizer version")
        }
        let data = try Data(contentsOf: versionURL)
        guard data.count <= 32,
              let rawVersion = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let version = Int(rawVersion),
              String(version) == rawVersion,
              supportedOptimizerVersions.contains(version) else {
            throw EpubError.invalidEpub("Unsupported Android EPUB optimizer version")
        }
    }

    /**
     Verifies the Room database is complete, internally consistent, and on the known schema version.

     - Parameter database: Open read-only Android optimization database.
     - Side effects: Executes integrity, user-version, and table-info queries only.
     - Throws: `EpubError.invalidEpub` for failed integrity, version drift, or missing required columns.
     */
    private static func validateRoomDatabase(_ database: OpaquePointer) throws {
        try validateSQLiteIntegrity(database, description: "Android optimized EPUB database")
        guard try integerPragma("user_version", database: database) == 1 else {
            throw EpubError.invalidEpub("Unsupported Android optimized EPUB database version")
        }
        try requireColumns(
            ["id", "originalId", "ordinalStart", "ordinalEnd"],
            table: "EpubFragment",
            database: database
        )
        try requireColumns(
            ["htmlId", "fragId"],
            table: "EpubHtmlToFrag",
            database: database
        )
        try requireColumns(
            ["id", "origId", "styleSheetFile"],
            table: "StyleSheet",
            database: database
        )
    }

    /**
     Loads, path-matches, decompresses, and transforms every Android fragment in numeric key order.

     - Parameters:
       - database: Validated Android Room database.
       - artifacts: Exact optimizer artifact locations.
       - package: Parsed OPF package.
       - packageRootURL: Copied immutable package root used for resource containment.
       - resourceIdentity: Generation-scoped route identity.
       - fileManager: File-system implementation used to enumerate fragment members.
     - Returns: Non-empty validated fragment rows retaining Android IDs and ordinal ranges.
     - Side effects: Reads Room rows and gzip fragment files and parses XML in memory.
     - Throws: `EpubError` for row, path, gzip, manifest, ordinal, or XML mismatches.
     */
    private static func loadFragments(
        database: OpaquePointer,
        artifacts: Artifacts,
        package: EpubPackageDocument,
        packageRootURL: URL,
        resourceIdentity: EpubResourceIdentity,
        fileManager: FileManager
    ) throws -> [FragmentRecord] {
        let spineItems = try renderableSpineItems(package: package)
        let itemByID = Dictionary(uniqueKeysWithValues: spineItems.map { ($0.item.id, $0.item) })
        let expectedOriginalIDs = Set(itemByID.keys)
        let fragmentFiles = try optimizedFragmentFiles(
            in: artifacts.optimizedDirectoryURL,
            fileManager: fileManager
        )

        let sql = """
            SELECT id, originalId, ordinalStart, ordinalEnd
            FROM EpubFragment
            ORDER BY id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB fragments")
        }
        defer { sqlite3_finalize(statement) }

        var records: [FragmentRecord] = []
        var seenIDs = Set<Int>()
        var representedOriginalIDs = Set<String>()
        var expectedFileNames = Set<String>()
        var expandedFragmentBytes: UInt64 = 0
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let id = exactInteger(statement, index: 0), id > 0,
                  seenIDs.insert(id).inserted,
                  let originalID = EpubReader.columnText(statement, index: 1),
                  expectedOriginalIDs.contains(originalID),
                  let ordinalStart = exactInteger(statement, index: 2), ordinalStart >= 0,
                  let ordinalEnd = exactInteger(statement, index: 3), ordinalEnd >= ordinalStart,
                  let item = itemByID[originalID] else {
                throw EpubError.invalidEpub("Android optimized EPUB fragment row does not match the OPF")
            }
            let fileName = String(format: "%03d.xhtml.gz", id)
            guard expectedFileNames.insert(fileName).inserted,
                  let fragmentURL = fragmentFiles[fileName] else {
                throw EpubError.invalidEpub(
                    "Android optimized EPUB fragment database/path mismatch for key \(id)"
                )
            }
            let fragmentData = try EpubAndroidGzipDecoder.data(
                sourceURL: fragmentURL,
                temporaryDirectoryURL: packageRootURL.deletingLastPathComponent(),
                maximumOutputBytes: EpubReader.maximumArchiveEntryByteCount
            )
            let fragmentBytes = UInt64(fragmentData.count)
            guard fragmentBytes <= EpubReader.maximumArchiveByteCount,
                  expandedFragmentBytes
                    <= EpubReader.maximumArchiveByteCount - fragmentBytes else {
                throw EpubError.invalidEpub(
                    "Android optimized EPUB fragments exceed the extraction limit"
                )
            }
            expandedFragmentBytes += fragmentBytes
            let transformed = try EpubAndroidOptimizedContentTransformer.transform(
                data: fragmentData,
                item: item,
                package: package,
                packageRootURL: packageRootURL,
                resourceIdentity: resourceIdentity,
                expectedOrdinalRange: ordinalStart...ordinalEnd
            )
            records.append(FragmentRecord(
                id: id,
                originalID: originalID,
                ordinalRange: ordinalStart...ordinalEnd,
                transformed: transformed
            ))
            representedOriginalIDs.insert(originalID)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteInvalid(database, operation: "reading Android EPUB fragments")
        }
        guard !records.isEmpty,
              representedOriginalIDs == expectedOriginalIDs,
              expectedFileNames == Set(fragmentFiles.keys) else {
            throw EpubError.invalidEpub(
                "Android optimized EPUB fragments do not exactly cover the OPF spine"
            )
        }
        return records
    }

    /**
     Returns OPF spine items Android is expected to have optimized, preserving reading order.

     - Parameter package: Parsed OPF package.
     - Returns: Spine ordinals paired with XHTML/HTML manifest items.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` for missing references or unsupported linear media types.
     */
    static func renderableSpineItems(
        package: EpubPackageDocument
    ) throws -> [(ordinal: Int, item: EpubManifestItem)] {
        var result: [(ordinal: Int, item: EpubManifestItem)] = []
        for (ordinal, spineItem) in package.spine.enumerated() {
            guard let item = package.manifestByID[spineItem.idref] else {
                throw EpubError.invalidEpub("Spine references missing item \(spineItem.idref)")
            }
            if item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" {
                result.append((ordinal, item))
            } else if spineItem.isLinear {
                throw EpubError.invalidEpub("Unsupported linear spine media type \(item.mediaType)")
            }
        }
        guard !result.isEmpty else {
            throw EpubError.invalidEpub("Package has no renderable spine content")
        }
        return result
    }

    /**
     Enumerates only Android's padded gzip fragment members and rejects hidden/special extras.

     - Parameters:
       - optimizedDirectoryURL: Android `optimized/` directory.
       - fileManager: File-system implementation used for listing and metadata.
     - Returns: Exact filename-to-file map excluding the required `version.txt` marker.
     - Side effects: Reads directory metadata only.
     - Throws: `EpubError.invalidEpub` for symbolic links, directories, special files, unexpected
       names, duplicates, or compressed files over the per-member limit.
     */
    private static func optimizedFragmentFiles(
        in optimizedDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> [String: URL] {
        let children = try fileManager.contentsOfDirectory(
            at: optimizedDirectoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: []
        )
        guard children.count <= EpubReader.maximumArchiveEntryCount + 1 else {
            throw EpubError.invalidEpub("Android optimized EPUB contains too many fragments")
        }
        var result: [String: URL] = [:]
        for child in children {
            let name = child.lastPathComponent
            let values = try child.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            if name == "version.txt" {
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= 32 else {
                    throw EpubError.invalidEpub("Unsupported Android EPUB optimizer version")
                }
                continue
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  name.range(of: #"^[0-9]{3,}\.xhtml\.gz$"#, options: .regularExpression) != nil,
                  UInt64(max(0, values.fileSize ?? 0)) <= EpubReader.maximumArchiveEntryByteCount,
                  result.updateValue(child, forKey: name) == nil else {
                throw EpubError.invalidEpub("Unexpected Android optimized EPUB fragment path \(name)")
            }
        }
        return result
    }

    /**
     Loads Android's exact base/id mappings and proves each row points into its declared fragment.

     - Parameters:
       - database: Validated Android Room database.
       - fragments: Parsed fragments keyed by their retained Android IDs.
     - Returns: Mapping rows ready for the native `anchor_map` table.
     - Side effects: Reads SQLite rows only.
     - Throws: `EpubError.invalidEpub` for unknown keys, cross-document targets, absent XHTML ids,
       duplicate projected mappings, or a base mapping not pointing to the first fragment.
     */
    private static func loadAnchorMappings(
        database: OpaquePointer,
        fragments: [FragmentRecord]
    ) throws -> [AnchorMapping] {
        let fragmentByID = Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, $0) })
        let firstIDByOriginal = Dictionary(grouping: fragments, by: \.originalID)
            .mapValues { rows in rows.map(\.id).min() ?? 0 }
        let sql = "SELECT htmlId, fragId FROM EpubHtmlToFrag ORDER BY htmlId"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB anchor mappings")
        }
        defer { sqlite3_finalize(statement) }

        var mappings: [AnchorMapping] = []
        var seen = Set<String>()
        var baseMappings: [String: Int] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let rawHTMLID = EpubReader.columnText(statement, index: 0),
                  !rawHTMLID.isEmpty,
                  let fragmentID = exactInteger(statement, index: 1),
                  let fragment = fragmentByID[fragmentID] else {
                throw EpubError.invalidEpub("Android EPUB anchor mapping references a missing fragment")
            }
            let htmlID: String
            if rawHTMLID == fragment.originalID {
                htmlID = ""
                baseMappings[fragment.originalID] = fragmentID
            } else {
                let prefix = fragment.originalID + "#"
                guard rawHTMLID.hasPrefix(prefix), rawHTMLID.count > prefix.count else {
                    throw EpubError.invalidEpub(
                        "Android EPUB anchor mapping crosses an OPF document boundary"
                    )
                }
                htmlID = String(rawHTMLID.dropFirst(prefix.count))
                guard fragment.transformed.fragment.htmlIDs.contains(htmlID) else {
                    throw EpubError.invalidEpub(
                        "Android EPUB anchor mapping points to an absent XHTML id"
                    )
                }
            }
            let projectedKey = EpubReader.composite(base: fragment.originalID, fragment: htmlID)
            guard seen.insert(projectedKey).inserted else {
                throw EpubError.invalidEpub("Android EPUB anchor mappings are ambiguous")
            }
            mappings.append(AnchorMapping(
                originalID: fragment.originalID,
                htmlID: htmlID,
                fragmentID: fragmentID
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteInvalid(database, operation: "reading Android EPUB anchor mappings")
        }
        guard baseMappings == firstIDByOriginal else {
            throw EpubError.invalidEpub("Android EPUB base mappings do not match fragment order")
        }
        let expectedProjectedKeys = Set(fragments.flatMap { fragment in
            [EpubReader.composite(base: fragment.originalID, fragment: "")]
                + fragment.transformed.fragment.htmlIDs.map {
                    EpubReader.composite(base: fragment.originalID, fragment: $0)
                }
        })
        guard seen == expectedProjectedKeys else {
            throw EpubError.invalidEpub("Android EPUB anchor mappings do not cover imported XHTML ids")
        }
        return mappings
    }

    /**
     Verifies every `epubRef` retained in native HTML has an exact Room mapping.

     - Parameters:
       - fragments: Transformed Android fragments with recorded link targets.
       - mappings: Validated Room mappings.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when a link would rely on reader fallback instead of resolving
       to Android's exact target fragment.
     */
    private static func validateInternalLinks(
        fragments: [FragmentRecord],
        mappings: [AnchorMapping]
    ) throws {
        let mappedTargets = Set(mappings.map {
            EpubAndroidInternalLinkTarget(originalKey: $0.originalID, htmlID: $0.htmlID)
        })
        for target in fragments.flatMap(\.transformed.internalLinkTargets) {
            guard mappedTargets.contains(target) else {
                throw EpubError.invalidEpub("Android optimized EPUB link has no exact fragment mapping")
            }
        }
    }

    /**
     Loads Android stylesheet rows and resolves each path relative to its original XHTML document.

     - Parameters:
       - database: Validated Android Room database.
       - fragments: Imported fragments establishing valid original IDs.
       - package: Parsed OPF package.
       - packageRootURL: Copied package root used for containment checks.
     - Returns: Styles in Android row-id order with canonical package paths.
     - Side effects: Reads SQLite only.
     - Throws: `EpubError.invalidEpub` for unknown original IDs or escaping/external CSS paths.
     */
    private static func loadStyles(
        database: OpaquePointer,
        fragments: [FragmentRecord],
        package: EpubPackageDocument,
        packageRootURL: URL
    ) throws -> [StyleRecord] {
        let validOriginalIDs = Set(fragments.map(\.originalID))
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        let sql = "SELECT origId, styleSheetFile FROM StyleSheet ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB stylesheets")
        }
        defer { sqlite3_finalize(statement) }

        var styles: [StyleRecord] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let originalID = EpubReader.columnText(statement, index: 0),
                  validOriginalIDs.contains(originalID),
                  let rawPath = EpubReader.columnText(statement, index: 1),
                  let item = package.manifestByID[originalID],
                  let resolved = try resolver.resolve(rawPath, relativeTo: item.path) else {
                throw EpubError.invalidEpub("Android EPUB stylesheet path does not match the OPF")
            }
            styles.append(StyleRecord(originalID: originalID, path: resolved.path))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteInvalid(database, operation: "reading Android EPUB stylesheets")
        }
        return styles
    }

}
