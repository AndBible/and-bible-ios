// EpubReaderLibrary.swift -- staged EPUB installation and library identity

import CryptoKit
import Foundation

extension EpubReader {
    // MARK: - Explicit-root API for deterministic tests

    /**
     Installs an EPUB into an explicit isolated library root.

     - Parameters:
       - epubURL: Source archive URL.
       - libraryRootURL: Destination directory used by tests or isolated hosts.
     - Returns: Stable identifier.
     - Side effects: Performs staged extraction, index construction, and atomic publication.
     - Throws: Same failures as the public install API.
     */
    static func install(epubURL: URL, libraryRootURL: URL) throws -> String {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
        // Apple filesystems can expose a decomposed path component for an NFC provider filename.
        // Normalize once so persisted source identity and Android's character-wise regex stay stable.
        let sourceFileName = epubURL.lastPathComponent.precomposedStringWithCanonicalMapping
        let identifier = stableIdentifier(forSourceFileName: sourceFileName)
        let bookInitials = initials(forDisplayFileName: sourceFileName)
        if let conflict = installedEpubs(libraryRootURL: libraryRootURL).first(where: {
            $0.identifier != identifier && $0.initials == bookInitials
        }) {
            throw EpubError.identityConflict(
                initials: bookInitials,
                existingFileName: conflict.sourceFileName,
                incomingFileName: sourceFileName
            )
        }

        let accessing = epubURL.startAccessingSecurityScopedResource()
        defer { if accessing { epubURL.stopAccessingSecurityScopedResource() } }

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
        let stagingRoot = stagingGeneration.appendingPathComponent("package", isDirectory: true)
        let stagingIndex = stagingGeneration.appendingPathComponent("index.sqlite3")
        defer { try? fileManager.removeItem(at: stagingGeneration) }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        do {
            let entries = try ZipArchiveReader.fileEntries(inArchiveAt: epubURL)
            guard !entries.isEmpty else { throw EpubError.invalidEpub("ZIP archive is empty") }
            guard entries.count <= maximumArchiveEntryCount else {
                throw EpubError.invalidEpub("ZIP archive contains too many files")
            }
            var canonicalPaths = Set<String>()
            var filesystemPaths = Set<String>()
            var totalUncompressedBytes: UInt64 = 0
            for entry in entries {
                guard entry.uncompressedSize <= maximumArchiveEntryByteCount,
                      entry.uncompressedSize <= maximumArchiveByteCount,
                      totalUncompressedBytes <= maximumArchiveByteCount - entry.uncompressedSize else {
                    throw EpubError.invalidEpub("ZIP archive exceeds the EPUB extraction limit")
                }
                totalUncompressedBytes += entry.uncompressedSize
            }
            var extractedFileCount = 0
            for entry in entries {
                guard let canonicalPath = canonicalArchiveEntryPath(entry.name) else {
                    throw EpubError.invalidEpub("Unsafe ZIP member path: \(entry.name)")
                }
                guard canonicalPaths.insert(canonicalPath).inserted else {
                    throw EpubError.invalidEpub("Duplicate ZIP member path: \(canonicalPath)")
                }
                let filesystemPath = canonicalPath
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
                guard filesystemPaths.insert(filesystemPath).inserted else {
                    throw EpubError.invalidEpub(
                        "ZIP member paths collide on the destination filesystem: \(canonicalPath)"
                    )
                }
                let destination = stagingRoot.appendingPathComponent(canonicalPath)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw EpubError.invalidEpub(
                        "ZIP member paths resolve to the same destination: \(canonicalPath)"
                    )
                }
                try ZipArchiveReader.extract(entry, fromArchiveAt: epubURL, to: destination)
                extractedFileCount += 1
            }
            guard extractedFileCount > 0 else { throw EpubError.invalidEpub("ZIP archive has no files") }
            try buildIndex(
                packageRootURL: stagingRoot,
                indexURL: stagingIndex,
                resourceIdentity: EpubResourceIdentity(
                    bookInitials: bookInitials,
                    generationIdentifier: generationIdentifier
                ),
                sourceFileName: sourceFileName
            )
        } catch let error as ZipArchiveReaderError {
            switch error {
            case .missingCentralDirectory:
                throw EpubError.invalidEpub("ZIP archive has no readable central directory")
            case .invalidArchive(let message):
                throw EpubError.invalidEpub(message)
            case .unsupportedCompressionMethod(let method):
                throw EpubError.invalidEpub("Unsupported ZIP compression method \(method)")
            case .decompressionFailed:
                throw EpubError.decompressionFailed
            }
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

    /// Lists installed EPUB metadata under an explicit library root.
    static func installedEpubs(libraryRootURL: URL) -> [EpubInfo] {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: libraryRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try? migrateLegacyInstallIfNeeded(
                identifier: child.lastPathComponent,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        }

        guard let publishedChildren = try? fileManager.contentsOfDirectory(
            at: libraryRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [EpubInfo] = []
        for child in publishedChildren where child.lastPathComponent.hasSuffix(generationManifestSuffix) {
            let identifier = String(child.lastPathComponent.dropLast(generationManifestSuffix.count))
            guard let reader = EpubReader(identifier: identifier, libraryRootURL: libraryRootURL) else { continue }
            result.append(EpubInfo(
                identifier: identifier,
                initials: reader.initials,
                sourceFileName: reader.sourceFileName,
                title: reader.title,
                author: reader.author,
                language: reader.language
            ))
        }
        if let containers = try? fileManager.contentsOfDirectory(
            at: generationsRootURL(libraryRootURL: libraryRootURL),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for container in containers {
                pruneGenerations(
                    identifier: container.lastPathComponent,
                    libraryRootURL: libraryRootURL,
                    fileManager: fileManager
                )
            }
        }
        return result.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            return titleOrder == .orderedSame ? $0.initials < $1.initials : titleOrder == .orderedAscending
        }
    }

    /**
     Removes one EPUB's published identity as a rollback-capable file-system transaction.

     Published and legacy paths move into a same-volume staging directory before the deletion is
     considered committed. A failed move restores every prior path in reverse order. Immutable
     generations are pruned only after the stable pointer is gone; leased generations remain usable
     until their readers close, matching Android's active-document lifetime.

     - Parameters:
       - identifier: Path-safe stable identifier returned by EPUB installation.
       - libraryRootURL: Root containing published EPUB pointers and immutable generations.
       - fileManager: File-system implementation used for transaction moves and deterministic tests.
     - Side effects: Moves published paths, removes staged legacy data after commit, and prunes
       unleased immutable generations.
     - Throws: `EpubError.invalidEpub` for unsafe identifiers or file-system errors before commit.
       Failed moves restore all previously moved paths before returning.
     */
    static func delete(
        identifier: String,
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        guard !identifier.isEmpty,
              identifier != ".",
              identifier != "..",
              identifier == URL(fileURLWithPath: identifier).lastPathComponent else {
            throw EpubError.invalidEpub("Unsafe EPUB library identifier")
        }
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let deletionRoot = libraryRootURL.appendingPathComponent(".epub-deletions", isDirectory: true)
        let stagingURL = deletionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let publishedURLs = [
            generationManifestURL(identifier: identifier, libraryRootURL: libraryRootURL),
            libraryRootURL.appendingPathComponent(identifier, isDirectory: true),
            legacyIndexURL(identifier: identifier, libraryRootURL: libraryRootURL),
        ]
        var movedPaths: [(original: URL, staged: URL)] = []
        do {
            for (index, originalURL) in publishedURLs.enumerated()
                where fileManager.fileExists(atPath: originalURL.path) {
                let stagedURL = stagingURL.appendingPathComponent(
                    "\(index)-\(originalURL.lastPathComponent)",
                    isDirectory: originalURL.hasDirectoryPath
                )
                try fileManager.moveItem(at: originalURL, to: stagedURL)
                movedPaths.append((originalURL, stagedURL))
            }
        } catch {
            let originalError = error
            do {
                for path in movedPaths.reversed() {
                    try fileManager.moveItem(at: path.staged, to: path.original)
                }
                try? fileManager.removeItem(at: stagingURL)
            } catch {
                throw EpubError.invalidEpub(
                    "EPUB deletion failed and rollback could not restore the library: "
                        + "\(originalError.localizedDescription); \(error.localizedDescription)"
                )
            }
            throw originalError
        }

        pruneGenerations(
            identifier: identifier,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        try? fileManager.removeItem(at: stagingURL)
        if (try? fileManager.contentsOfDirectory(atPath: deletionRoot.path).isEmpty) == true {
            try? fileManager.removeItem(at: deletionRoot)
        }
    }

    // MARK: - Archive/path validation and stable Android identity

    /// Validates one ZIP member path before extraction into the staging root.
    private static func canonicalArchiveEntryPath(_ name: String) -> String? {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.hasPrefix("~"),
              !name.contains("\\"),
              !name.contains("\0") else {
            return nil
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    /**
     Derives a collision-resistant directory and module identity from the exact source filename.

     Android keeps the unsanitized display filename as the EPUB directory and replaces only that
     exact directory on reinstall, but `epubInitials(dirName)` can collapse punctuation variants.
     iOS needs an ASCII path token, so it retains a readable stem and appends a deterministic
     fingerprint of the exact filename. Exact-name reinstalls remain stable while spaces,
     punctuation, Unicode, and case-only variants cannot overwrite or alias another general book.

     - Parameter sourceFileName: Last path component of the imported archive, including extension.
     - Returns: ASCII identifier no longer than 113 characters.
     - Side effects: None.
     - Failure modes: None; punctuation-only names use `book` as the readable stem.
     */
    static func stableIdentifier(forSourceFileName sourceFileName: String) -> String {
        let sourceStem = (sourceFileName.precomposedStringWithCanonicalMapping as NSString)
            .deletingPathExtension
        let mapped = sourceStem.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122
            return Character(isDigit || isUpper || isLower || scalar == "-" || scalar == "_"
                ? String(scalar)
                : "_")
        }
        let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let readableStem = String((sanitized.isEmpty ? "book" : sanitized).prefix(80))
        let digest = SHA256.hash(data: Data(sourceFileName.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(readableStem)-\(digest)"
    }

    /// Combines a base key/href with an optional fragment.
    static func composite(base: String, fragment: String?) -> String {
        guard let fragment, !fragment.isEmpty else { return base }
        return "\(base)#\(fragment)"
    }

    /// Splits a composite key/href at its first fragment delimiter.
    static func splitComposite(_ value: String) -> (base: String, fragment: String?) {
        guard let separator = value.firstIndex(of: "#") else { return (value, nil) }
        let base = String(value[..<separator])
        let fragmentStart = value.index(after: separator)
        let fragment = String(value[fragmentStart...])
        return (base, fragment.isEmpty ? nil : fragment)
    }

}
