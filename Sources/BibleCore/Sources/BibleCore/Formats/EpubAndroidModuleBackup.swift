// EpubAndroidModuleBackup.swift -- Android MODULE_BACKUP EPUB tree installation

import Foundation

/** Android-visible EPUB metadata restored from one validated package document. */
struct EpubAndroidModuleMetadata: Sendable, Equatable {
    /// Dublin Core title, falling back to Android's display directory name.
    let title: String

    /// Dublin Core description, falling back to Android's display directory name.
    let description: String

    /// Dublin Core language, falling back to `en`.
    let language: String
}

extension EpubReader {
    /**
     Reads Android's generated-book metadata from an extracted EPUB tree without publishing it.

     - Parameter epubDirectoryURL: Exact real `epub/<displayName>` package directory.
     - Returns: Title, description, and language using Android's package-metadata fallbacks.
     - Side effects: Reads directory metadata, container XML, and the package document only.
     - Throws: `EpubError` or file-system errors for symlinked, incomplete, or malformed packages.
     */
    static func androidModuleMetadata(
        epubDirectoryURL: URL
    ) throws -> EpubAndroidModuleMetadata {
        let sourceRootURL = epubDirectoryURL.standardizedFileURL
        try validateAndroidDirectoryRoot(sourceRootURL, fileManager: .default)
        let displayName = sourceRootURL.lastPathComponent.precomposedStringWithCanonicalMapping
        guard !displayName.isEmpty, displayName != ".", displayName != ".." else {
            throw EpubError.invalidEpub("Android EPUB directory has no display name")
        }
        let package = try EpubPackageDocumentParser.parse(packageRootURL: sourceRootURL)
        return EpubAndroidModuleMetadata(
            title: package.title ?? displayName,
            description: package.description ?? displayName,
            language: package.language
        )
    }

    /**
     Installs one Android EPUB tree into an explicit isolated library root.

     Raw trees use the ordinary OPF/XHTML indexer. Optimized trees whose original spine documents
     Android deleted are imported from the Room database and gzip fragments while preserving their
     numeric fragment IDs. Both paths publish through the same immutable generation pointer.

     - Parameters:
       - epubDirectoryURL: Exact Android `epub/<displayName>/` directory.
       - libraryRootURL: Destination EPUB library used by tests or isolated hosts.
     - Returns: Collision-resistant local identifier whose index retains Android's exact initials.
     - Side effects: Copies package files, creates SQLite state, and atomically replaces the current
       generation only after all validation and indexing succeeds.
     - Throws: `EpubError` or file-system failures. Staging data is removed on every failure.
     - Important: The method serializes against all EPUB publication, migration, and deletion work.
     */
    static func installAndroidModuleBackup(
        epubDirectoryURL: URL,
        libraryRootURL: URL
    ) throws -> String {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }

        let fileManager = FileManager.default
        let sourceRootURL = epubDirectoryURL.standardizedFileURL
        let accessing = sourceRootURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceRootURL.stopAccessingSecurityScopedResource() } }
        try validateAndroidDirectoryRoot(sourceRootURL, fileManager: fileManager)
        let displayName = sourceRootURL.lastPathComponent.precomposedStringWithCanonicalMapping
        guard !displayName.isEmpty, displayName != ".", displayName != ".." else {
            throw EpubError.invalidEpub("Android EPUB directory has no display name")
        }

        try fileManager.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
        let identifier = stableIdentifier(forSourceFileName: displayName)
        let bookInitials = initials(forDisplayFileName: displayName)
        if let conflict = installedEpubs(libraryRootURL: libraryRootURL).first(where: {
            $0.identifier != identifier && $0.initials == bookInitials
        }) {
            throw EpubError.identityConflict(
                initials: bookInitials,
                existingFileName: conflict.sourceFileName,
                incomingFileName: displayName
            )
        }

        let generationIdentifier = newGenerationIdentifier()
        let generationContainer = generationContainerURL(
            identifier: identifier,
            libraryRootURL: libraryRootURL
        )
        try fileManager.createDirectory(at: generationContainer, withIntermediateDirectories: true)
        let stagingGeneration = generationContainer.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingPackage = stagingGeneration.appendingPathComponent("package", isDirectory: true)
        let stagingIndex = stagingGeneration.appendingPathComponent("index.sqlite3")
        defer { try? fileManager.removeItem(at: stagingGeneration) }
        try fileManager.createDirectory(at: stagingPackage, withIntermediateDirectories: true)

        try copyAndroidPackageTree(
            from: sourceRootURL,
            to: stagingPackage,
            fileManager: fileManager,
            bookInitials: bookInitials
        )
        let package = try EpubPackageDocumentParser.parse(packageRootURL: stagingPackage)
        let resourceIdentity = EpubResourceIdentity(
            bookInitials: bookInitials,
            generationIdentifier: generationIdentifier
        )
        if rawSpineIsComplete(
            package: package,
            packageRootURL: stagingPackage,
            fileManager: fileManager
        ) {
            try buildIndex(
                packageRootURL: stagingPackage,
                indexURL: stagingIndex,
                resourceIdentity: resourceIdentity,
                sourceFileName: displayName
            )
        } else {
            try EpubAndroidOptimizedIndexImporter.buildIndex(
                androidRootURL: sourceRootURL,
                packageRootURL: stagingPackage,
                indexURL: stagingIndex,
                package: package,
                resourceIdentity: resourceIdentity,
                sourceFileName: displayName
            )
        }

        try publishPreparedGeneration(
            stagingGenerationURL: stagingGeneration,
            manifest: EpubGenerationManifest(
                schemaVersion: generationManifestVersion,
                identifier: identifier,
                generationIdentifier: generationIdentifier
            ),
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        return identifier
    }

    /**
     Validates that the Android payload root is a readable real directory, not an interrupted install.

     - Parameters:
       - sourceRootURL: Candidate `epub/<displayName>/` path.
       - fileManager: File-system implementation used for metadata checks.
     - Side effects: Reads file metadata only.
     - Throws: `EpubError.invalidEpub` for missing, non-directory, symbolic-link, or `optimize.lock`
       roots. Android itself deletes modules carrying this interrupted-optimization marker.
     */
    private static func validateAndroidDirectoryRoot(
        _ sourceRootURL: URL,
        fileManager: FileManager
    ) throws {
        let values = try sourceRootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isReadableKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isReadable != false else {
            throw EpubError.invalidEpub("Android EPUB payload is not a readable directory")
        }
        let lockURL = sourceRootURL.appendingPathComponent("optimize.lock")
        guard !fileManager.fileExists(atPath: lockURL.path) else {
            throw EpubError.invalidEpub("Android EPUB optimization was interrupted")
        }
    }

    /**
     Copies package-owned files from an Android install tree into immutable generation staging.

     Android's `optimized/` fragments and root SQLite artifacts are implementation state, not EPUB
     resources, and are intentionally excluded from the published package. Every copied path is
     checked for containment, normalization/case collisions, symbolic links, special files, and the
     same count/size ceilings used by archive installation.

     - Parameters:
       - sourceRootURL: Validated Android EPUB directory.
       - destinationRootURL: Empty staging `package/` directory.
       - fileManager: File-system implementation used for enumeration and copying.
       - bookInitials: Android EPUB identity used to recognize exact optimizer database filenames.
     - Side effects: Creates directories and copies regular files beneath `destinationRootURL`.
     - Throws: File-system or `EpubError.invalidEpub` failures. The caller owns staging cleanup.
     */
    private static func copyAndroidPackageTree(
        from sourceRootURL: URL,
        to destinationRootURL: URL,
        fileManager: FileManager,
        bookInitials: String
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: sourceRootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw EpubError.invalidEpub("Unable to enumerate Android EPUB payload")
        }

        var canonicalPaths = Set<String>()
        var filesystemPaths = Set<String>()
        var copiedFileCount = 0
        var totalBytes: UInt64 = 0
        for case let sourceURL as URL in enumerator {
            let relativePath = try androidRelativePath(of: sourceURL, rootURL: sourceRootURL)
            let values = try sourceURL.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw EpubError.invalidEpub("Android EPUB payload contains a symbolic link: \(relativePath)")
            }

            if isAndroidOptimizationArtifact(relativePath, bookInitials: bookInitials) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard canonicalPaths.insert(relativePath).inserted else {
                throw EpubError.invalidEpub("Duplicate Android EPUB path: \(relativePath)")
            }
            let filesystemPath = relativePath
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard filesystemPaths.insert(filesystemPath).inserted else {
                throw EpubError.invalidEpub(
                    "Android EPUB paths collide on the destination filesystem: \(relativePath)"
                )
            }

            let destinationURL = destinationRootURL.appendingPathComponent(relativePath)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else {
                throw EpubError.invalidEpub("Android EPUB payload contains a special file: \(relativePath)")
            }
            let fileBytes = UInt64(max(0, values.fileSize ?? 0))
            guard fileBytes <= maximumArchiveEntryByteCount,
                  fileBytes <= maximumArchiveByteCount,
                  totalBytes <= maximumArchiveByteCount - fileBytes else {
                throw EpubError.invalidEpub("Android EPUB payload exceeds the extraction limit")
            }
            totalBytes += fileBytes
            copiedFileCount += 1
            guard copiedFileCount <= maximumArchiveEntryCount else {
                throw EpubError.invalidEpub("Android EPUB payload contains too many files")
            }
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        if let enumerationError {
            throw enumerationError
        }
        guard copiedFileCount > 0 else {
            throw EpubError.invalidEpub("Android EPUB payload has no package files")
        }
    }

    /**
     Produces one canonical relative path for a directory member without resolving symbolic links.

     - Parameters:
       - memberURL: Enumerated descendant URL.
       - rootURL: Validated Android EPUB root.
     - Returns: Forward-slash path whose components are non-empty and non-traversing.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when the member is not a strict contained descendant or uses
       a backslash/NUL/relative traversal component.
     */
    private static func androidRelativePath(of memberURL: URL, rootURL: URL) throws -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let memberComponents = memberURL.standardizedFileURL.pathComponents
        guard memberComponents.count > rootComponents.count,
              Array(memberComponents.prefix(rootComponents.count)) == rootComponents else {
            throw EpubError.invalidEpub("Android EPUB member escapes its display-name directory")
        }
        let components = memberComponents.dropFirst(rootComponents.count)
        guard components.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("\\")
                && !component.contains("\0")
        }) else {
            throw EpubError.invalidEpub("Android EPUB member has an unsafe path")
        }
        return components.joined(separator: "/")
    }

    /**
     Identifies Android-generated optimization state that must not become a served EPUB resource.

     - Parameters:
       - relativePath: Canonical path beneath the Android display-name directory.
       - bookInitials: Exact Android EPUB identity embedded in optimizer database names.
     - Returns: `true` for `optimized/`, optimizer locks, Room gzip files, search databases, and their
       SQLite sidecars; `false` for package container/OPF/resource members.
     - Side effects: None.
     - Failure modes: None; matching is deliberately case-sensitive to mirror Android filenames.
     */
    private static func isAndroidOptimizationArtifact(
        _ relativePath: String,
        bookInitials: String
    ) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if components.first == "optimized" {
            return true
        }
        guard components.count == 1, let fileName = components.first.map(String.init) else {
            return false
        }
        if fileName == "optimize.lock" || fileName == "optimized.sqlite3.gz" {
            return true
        }
        let databaseNames = [
            "epub-\(bookInitials).sqlite3",
            "epub-\(bookInitials).sqlite3.gz",
            "epub-\(bookInitials)-search.sqlite3",
        ]
        return databaseNames.contains { databaseName in
            fileName == databaseName
                || fileName == databaseName + "-wal"
                || fileName == databaseName + "-shm"
                || fileName == databaseName + "-journal"
        }
    }

    /**
     Reports whether every XHTML/HTML spine source needed by the ordinary indexer survived Android.

     - Parameters:
       - package: Validated OPF package model.
       - packageRootURL: Copied immutable package staging root.
       - fileManager: File-system implementation used for regular-file checks.
     - Returns: `true` when the raw indexer can read all renderable spine documents; otherwise
       `false`, selecting Android's optimized fragment importer.
     - Side effects: Reads file metadata only.
     - Failure modes: Missing manifest references return `false`; the selected indexer reports the
       detailed package error.
     */
    private static func rawSpineIsComplete(
        package: EpubPackageDocument,
        packageRootURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        for spineItem in package.spine {
            guard let item = package.manifestByID[spineItem.idref] else { return false }
            guard item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else {
                continue
            }
            guard let url = try? resolver.fileURL(for: item.path) else { return false }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return false
            }
        }
        return true
    }
}
