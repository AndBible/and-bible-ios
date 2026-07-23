// EpubReaderGeneration.swift -- immutable EPUB package/index publication and leases

import Foundation

/**
 Private generation identity carried by every EPUB resource URL.

 `bookInitials` remains Android's portable general-book identity. `generationIdentifier` is an
 iOS-local immutable package snapshot token and must never be persisted as module initials.
 */
public struct EpubResourceIdentity: Equatable, Hashable, Sendable {
    /// Android-compatible EPUB module initials.
    public let bookInitials: String

    /// Opaque iOS-local immutable package generation token.
    public let generationIdentifier: String

    /** Creates one validated-by-caller resource identity without filesystem side effects. */
    public init(bookInitials: String, generationIdentifier: String) {
        self.bookInitials = bookInitials
        self.generationIdentifier = generationIdentifier
    }
}

/** Atomic stable-id pointer to one fully published immutable EPUB generation. */
struct EpubGenerationManifest: Codable, Equatable, Sendable {
    /// On-disk pointer schema for rejecting incompatible future layouts.
    let schemaVersion: Int

    /// Collision-resistant stable library identifier.
    let identifier: String

    /// Opaque generation directory name.
    let generationIdentifier: String
}

/** Resolved immutable package/index paths acquired under the EPUB library lock. */
struct EpubGenerationLocation: Equatable, Sendable {
    /// Stable library identifier whose pointer owns this generation.
    let identifier: String

    /// Opaque generation token.
    let generationIdentifier: String

    /// Immutable extracted package root.
    let packageRootURL: URL

    /// Immutable SQLite index paired with `packageRootURL`.
    let indexURL: URL
}

extension EpubReader {
    /// Current manifest schema version.
    static let generationManifestVersion = 1

    /// Hidden root containing all immutable package/index generations.
    static let generationsDirectoryName = ".epub-generations"

    /// Stable-pointer filename suffix.
    static let generationManifestSuffix = ".epub-current.json"

    /// In-process leases prevent old generations from being removed while readers still use them.
    private static var activeGenerationLeaseCounts: [String: Int] = [:]

    /** Returns the hidden generation root for one EPUB library. */
    static func generationsRootURL(libraryRootURL: URL) -> URL {
        libraryRootURL.appendingPathComponent(generationsDirectoryName, isDirectory: true)
    }

    /** Returns the generation container belonging to one stable identifier. */
    static func generationContainerURL(identifier: String, libraryRootURL: URL) -> URL {
        generationsRootURL(libraryRootURL: libraryRootURL)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    /** Returns one immutable generation directory. */
    static func generationURL(
        identifier: String,
        generationIdentifier: String,
        libraryRootURL: URL
    ) -> URL {
        generationContainerURL(identifier: identifier, libraryRootURL: libraryRootURL)
            .appendingPathComponent(generationIdentifier, isDirectory: true)
    }

    /** Returns the stable current-generation pointer URL for one book. */
    static func generationManifestURL(identifier: String, libraryRootURL: URL) -> URL {
        libraryRootURL.appendingPathComponent("\(identifier)\(generationManifestSuffix)")
    }

    /**
     Reads and validates one current-generation pointer.

     - Parameters:
       - identifier: Expected stable identifier.
       - libraryRootURL: EPUB library root.
     - Returns: Valid manifest, or `nil` for missing, malformed, mismatched, or unsafe data.
     - Side effects: Reads one small JSON file.
     - Failure modes: All decode and validation failures return `nil`; callers never follow an
       untrusted path component.
     */
    static func generationManifest(
        identifier: String,
        libraryRootURL: URL
    ) -> EpubGenerationManifest? {
        let url = generationManifestURL(identifier: identifier, libraryRootURL: libraryRootURL)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(EpubGenerationManifest.self, from: data),
              manifest.schemaVersion == generationManifestVersion,
              manifest.identifier == identifier,
              isSafeGenerationIdentifier(manifest.generationIdentifier) else {
            return nil
        }
        return manifest
    }

    /**
     Atomically publishes a prepared immutable generation by switching its stable JSON pointer.

     The staging directory must already contain `package/` and `index.sqlite3`. It is first renamed
     to its final immutable path; only then is the current pointer atomically replaced. A pointer
     write failure removes the unpublished final generation and leaves the prior pointer untouched.

     - Parameters:
       - stagingGenerationURL: Prepared generation directory in the destination container.
       - manifest: Pointer to publish.
       - libraryRootURL: EPUB library root.
       - fileManager: Filesystem implementation.
     - Side effects: Renames one directory, atomically writes one JSON file, and prunes unleased old
       generations after success.
     - Throws: Filesystem or encoding errors. The previous current generation remains selected.
     - Important: Caller must hold `libraryMutationLock`.
     */
    static func publishPreparedGeneration(
        stagingGenerationURL: URL,
        manifest: EpubGenerationManifest,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws {
        guard manifest.schemaVersion == generationManifestVersion,
              isSafeGenerationIdentifier(manifest.generationIdentifier),
              stagingGenerationURL.deletingLastPathComponent().standardizedFileURL
                == generationContainerURL(
                    identifier: manifest.identifier,
                    libraryRootURL: libraryRootURL
                ).standardizedFileURL else {
            throw EpubError.invalidEpub("Unsafe EPUB generation identity")
        }
        var packageIsDirectory: ObjCBool = false
        let stagingPackage = stagingGenerationURL.appendingPathComponent("package", isDirectory: true)
        let stagingIndex = stagingGenerationURL.appendingPathComponent("index.sqlite3")
        guard fileManager.fileExists(atPath: stagingPackage.path, isDirectory: &packageIsDirectory),
              packageIsDirectory.boolValue,
              fileManager.fileExists(atPath: stagingIndex.path) else {
            throw EpubError.indexingFailed("Prepared EPUB generation is incomplete")
        }
        let finalURL = generationURL(
            identifier: manifest.identifier,
            generationIdentifier: manifest.generationIdentifier,
            libraryRootURL: libraryRootURL
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw EpubError.indexingFailed("EPUB generation already exists")
        }
        try fileManager.moveItem(at: stagingGenerationURL, to: finalURL)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(
                to: generationManifestURL(
                    identifier: manifest.identifier,
                    libraryRootURL: libraryRootURL
                ),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: finalURL)
            throw error
        }
        pruneGenerations(
            identifier: manifest.identifier,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
    }

    /**
     Acquires the current immutable generation, migrating legacy layout or rebuilding stale indexes.

     - Parameters:
       - identifier: Stable library identifier.
       - libraryRootURL: EPUB library root.
     - Returns: Leased generation paths, or `nil` when migration/rebuild/open prerequisites fail.
     - Side effects: May copy a legacy/current package, rebuild an index into a new generation,
       atomically switch the pointer, and increment an in-process lease.
     - Important: The returned lease must be released exactly once.
     */
    static func acquireCurrentGeneration(
        identifier: String,
        libraryRootURL: URL
    ) -> EpubGenerationLocation? {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
            try migrateLegacyInstallIfNeeded(
                identifier: identifier,
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
            guard var manifest = generationManifest(
                identifier: identifier,
                libraryRootURL: libraryRootURL
            ) else {
                return nil
            }
            var location = location(for: manifest, libraryRootURL: libraryRootURL)
            guard fileManager.fileExists(atPath: location.packageRootURL.path) else { return nil }
            if !indexIsCurrent(indexURL: location.indexURL) {
                manifest = try rebuildGeneration(
                    from: location,
                    libraryRootURL: libraryRootURL,
                    fileManager: fileManager
                )
                location = self.location(for: manifest, libraryRootURL: libraryRootURL)
            }
            guard fileManager.fileExists(atPath: location.indexURL.path) else { return nil }
            retainGeneration(location, libraryRootURL: libraryRootURL)
            return location
        } catch {
            return nil
        }
    }

    /**
     Acquires one exact generation encoded in an already-rendered resource URL.

     Old generations remain addressable only while leased by an existing reader. Initials are
     verified against immutable index metadata, preventing a generation token from crossing books.

     - Parameters:
       - initials: Android-visible book identity encoded in the route.
       - generationIdentifier: Opaque generation token encoded in the route.
       - libraryRootURL: EPUB library root.
     - Returns: Exactly one leased generation, or `nil` for missing/ambiguous/mismatched routes.
     - Side effects: Scans generation metadata and increments one in-process lease.
     */
    static func acquireGeneration(
        initials: String,
        generationIdentifier: String,
        libraryRootURL: URL
    ) -> EpubGenerationLocation? {
        guard isSafeGenerationIdentifier(generationIdentifier) else { return nil }
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let fileManager = FileManager.default
        let generationsRoot = generationsRootURL(libraryRootURL: libraryRootURL)
        guard let containers = try? fileManager.contentsOfDirectory(
            at: generationsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var matches: [EpubGenerationLocation] = []
        for container in containers {
            guard (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let candidate = generationURL(
                identifier: container.lastPathComponent,
                generationIdentifier: generationIdentifier,
                libraryRootURL: libraryRootURL
            )
            let indexURL = candidate.appendingPathComponent("index.sqlite3")
            guard fileManager.fileExists(atPath: candidate.path),
                  metadataValue(at: indexURL, key: "initials") == initials,
                  metadataValue(at: indexURL, key: "generation") == generationIdentifier else {
                continue
            }
            matches.append(EpubGenerationLocation(
                identifier: container.lastPathComponent,
                generationIdentifier: generationIdentifier,
                packageRootURL: candidate.appendingPathComponent("package", isDirectory: true),
                indexURL: indexURL
            ))
        }
        guard matches.count == 1, let location = matches.first else { return nil }
        retainGeneration(location, libraryRootURL: libraryRootURL)
        return location
    }

    /** Releases one reader lease and removes generations no live reader/current pointer needs. */
    static func releaseGeneration(
        _ location: EpubGenerationLocation,
        libraryRootURL: URL
    ) {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let key = generationLeaseKey(location, libraryRootURL: libraryRootURL)
        if let count = activeGenerationLeaseCounts[key], count > 1 {
            activeGenerationLeaseCounts[key] = count - 1
        } else {
            activeGenerationLeaseCounts.removeValue(forKey: key)
        }
        pruneGenerations(
            identifier: location.identifier,
            libraryRootURL: libraryRootURL,
            fileManager: .default
        )
    }

    /**
     Migrates one pre-generation package/index pair by rebuilding generation-scoped native HTML.

     The legacy package is copied, not moved, until the new generation and pointer are complete.
     Existing resource URLs lack a generation token, so the old index is used only for source
     identity metadata and is never published into the new layout.

     - Throws: Copy, index, or atomic publication errors; legacy files remain intact on failure.
     - Important: Caller must hold `libraryMutationLock`.
     */
    static func migrateLegacyInstallIfNeeded(
        identifier: String,
        libraryRootURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyPackage = libraryRootURL.appendingPathComponent(identifier, isDirectory: true)
        let legacyIndex = legacyIndexURL(identifier: identifier, libraryRootURL: libraryRootURL)
        if generationManifest(identifier: identifier, libraryRootURL: libraryRootURL) != nil {
            try? fileManager.removeItem(at: legacyPackage)
            try? fileManager.removeItem(at: legacyIndex)
            return
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyPackage.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        let generationIdentifier = newGenerationIdentifier()
        let container = generationContainerURL(identifier: identifier, libraryRootURL: libraryRootURL)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let staging = container.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let stagingPackage = staging.appendingPathComponent("package", isDirectory: true)
        let stagingIndex = staging.appendingPathComponent("index.sqlite3")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyPackage, to: stagingPackage)
        let sourceFileName = metadataValue(at: legacyIndex, key: "source_file_name")
        let initials = metadataValue(at: legacyIndex, key: "initials")
            ?? self.initials(forDisplayFileName: identifier)
        try buildIndex(
            packageRootURL: stagingPackage,
            indexURL: stagingIndex,
            resourceIdentity: EpubResourceIdentity(
                bookInitials: initials,
                generationIdentifier: generationIdentifier
            ),
            sourceFileName: sourceFileName
        )
        try publishPreparedGeneration(
            stagingGenerationURL: staging,
            manifest: EpubGenerationManifest(
                schemaVersion: generationManifestVersion,
                identifier: identifier,
                generationIdentifier: generationIdentifier
            ),
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        try? fileManager.removeItem(at: legacyPackage)
        try? fileManager.removeItem(at: legacyIndex)
    }

    /**
     Rebuilds one explicitly requested index and opens the newly published immutable generation.

     This is the explicit-root implementation behind Android EPUB Search's Rebuild index command
     and deterministic tests. It uses the same publisher as automatic stale-index migration, so a
     live reader remains leased to its old generation while future opens select the replacement.

     - Parameters:
       - identifier: Stable installed EPUB identity.
       - libraryRootURL: Library root containing the current stable generation pointer.
     - Returns: A reader leased to the newly published generation.
     - Side effects: Copies the current package, builds a complete replacement index, atomically
       switches the stable pointer, and opens the replacement read-only.
     - Throws: Missing/unsafe generation state, index/publication failures, or failure to reopen the
       just-published generation. Publication failures retain the prior stable pointer.
     */
    static func rebuildSearchIndex(
        identifier: String,
        libraryRootURL: URL
    ) throws -> EpubReader {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let fileManager = FileManager.default
        guard let manifest = generationManifest(
            identifier: identifier,
            libraryRootURL: libraryRootURL
        ) else {
            throw EpubError.invalidEpub("Installed EPUB generation is unavailable")
        }
        let source = location(for: manifest, libraryRootURL: libraryRootURL)
        guard fileManager.fileExists(atPath: source.packageRootURL.path) else {
            throw EpubError.invalidEpub("Installed EPUB package is unavailable")
        }
        _ = try rebuildGeneration(
            from: source,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        guard let reader = EpubReader(identifier: identifier, libraryRootURL: libraryRootURL) else {
            throw EpubError.indexingFailed("Rebuilt EPUB index could not be opened")
        }
        return reader
    }

    /**
     Publishes an immutable EPUB generation with rendered content intact and FTS rows removed.

     - Parameters:
       - identifier: Stable installed EPUB identity.
       - libraryRootURL: Explicit library root for production or isolated tests.
     - Returns: Reader leased to the newly published index-free generation.
     - Side effects: Locks the library, stages a complete generation, clears only staged FTS rows,
       atomically switches the stable pointer, and reopens the result.
     - Throws: Missing package state, SQLite, publication, or reopen failures. The prior generation
       remains current on failure, and already-open readers retain their immutable leases.
     */
    static func deleteSearchIndex(
        identifier: String,
        libraryRootURL: URL
    ) throws -> EpubReader {
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }
        let fileManager = FileManager.default
        guard let manifest = generationManifest(
            identifier: identifier,
            libraryRootURL: libraryRootURL
        ) else {
            throw EpubError.invalidEpub("Installed EPUB generation is unavailable")
        }
        let source = location(for: manifest, libraryRootURL: libraryRootURL)
        guard fileManager.fileExists(atPath: source.packageRootURL.path) else {
            throw EpubError.invalidEpub("Installed EPUB package is unavailable")
        }
        _ = try rebuildGeneration(
            from: source,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager,
            includesSearchIndex: false
        )
        guard let reader = EpubReader(identifier: identifier, libraryRootURL: libraryRootURL) else {
            throw EpubError.indexingFailed("Index-free EPUB generation could not be opened")
        }
        return reader
    }

    /** Rebuilds a stale immutable index by publishing a completely new package/index generation. */
    private static func rebuildGeneration(
        from source: EpubGenerationLocation,
        libraryRootURL: URL,
        fileManager: FileManager,
        includesSearchIndex: Bool = true
    ) throws -> EpubGenerationManifest {
        let generationIdentifier = newGenerationIdentifier()
        let container = generationContainerURL(
            identifier: source.identifier,
            libraryRootURL: libraryRootURL
        )
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let staging = container.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let stagingPackage = staging.appendingPathComponent("package", isDirectory: true)
        let stagingIndex = staging.appendingPathComponent("index.sqlite3")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source.packageRootURL, to: stagingPackage)
        let sourceFileName = metadataValue(at: source.indexURL, key: "source_file_name")
        let initials = metadataValue(at: source.indexURL, key: "initials")
            ?? self.initials(forDisplayFileName: source.identifier)
        try buildIndex(
            packageRootURL: stagingPackage,
            indexURL: stagingIndex,
            resourceIdentity: EpubResourceIdentity(
                bookInitials: initials,
                generationIdentifier: generationIdentifier
            ),
            sourceFileName: sourceFileName
        )
        if !includesSearchIndex {
            try clearSearchIndex(at: stagingIndex)
        }
        let manifest = EpubGenerationManifest(
            schemaVersion: generationManifestVersion,
            identifier: source.identifier,
            generationIdentifier: generationIdentifier
        )
        try publishPreparedGeneration(
            stagingGenerationURL: staging,
            manifest: manifest,
            libraryRootURL: libraryRootURL,
            fileManager: fileManager
        )
        return manifest
    }

    /** Converts one validated manifest into immutable package/index paths. */
    private static func location(
        for manifest: EpubGenerationManifest,
        libraryRootURL: URL
    ) -> EpubGenerationLocation {
        let root = generationURL(
            identifier: manifest.identifier,
            generationIdentifier: manifest.generationIdentifier,
            libraryRootURL: libraryRootURL
        )
        return EpubGenerationLocation(
            identifier: manifest.identifier,
            generationIdentifier: manifest.generationIdentifier,
            packageRootURL: root.appendingPathComponent("package", isDirectory: true),
            indexURL: root.appendingPathComponent("index.sqlite3")
        )
    }

    /** Increments one generation lease while `libraryMutationLock` is held. */
    private static func retainGeneration(
        _ location: EpubGenerationLocation,
        libraryRootURL: URL
    ) {
        let key = generationLeaseKey(location, libraryRootURL: libraryRootURL)
        activeGenerationLeaseCounts[key, default: 0] += 1
    }

    /** Returns a canonical in-process key for generation lease accounting. */
    private static func generationLeaseKey(
        _ location: EpubGenerationLocation,
        libraryRootURL: URL
    ) -> String {
        generationURL(
            identifier: location.identifier,
            generationIdentifier: location.generationIdentifier,
            libraryRootURL: libraryRootURL
        ).standardizedFileURL.path
    }

    /** Removes every noncurrent generation with no in-process reader lease. */
    static func pruneGenerations(
        identifier: String,
        libraryRootURL: URL,
        fileManager: FileManager
    ) {
        let current = generationManifest(
            identifier: identifier,
            libraryRootURL: libraryRootURL
        )?.generationIdentifier
        let container = generationContainerURL(identifier: identifier, libraryRootURL: libraryRootURL)
        guard let generations = try? fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for generation in generations {
            let token = generation.lastPathComponent
            guard token != current else { continue }
            let location = EpubGenerationLocation(
                identifier: identifier,
                generationIdentifier: token,
                packageRootURL: generation.appendingPathComponent("package", isDirectory: true),
                indexURL: generation.appendingPathComponent("index.sqlite3")
            )
            guard activeGenerationLeaseCounts[generationLeaseKey(
                location,
                libraryRootURL: libraryRootURL
            )] == nil else {
                continue
            }
            try? fileManager.removeItem(at: generation)
        }
        if current == nil,
           (try? fileManager.contentsOfDirectory(atPath: container.path).isEmpty) == true {
            try? fileManager.removeItem(at: container)
        }
    }

    /** Returns the old top-level companion index path for one pre-generation install. */
    static func legacyIndexURL(identifier: String, libraryRootURL: URL) -> URL {
        libraryRootURL.appendingPathComponent("\(identifier).index.sqlite3")
    }

    /** Generates a path-safe opaque token; only equality, never ordering, is meaningful. */
    static func newGenerationIdentifier() -> String {
        UUID().uuidString.lowercased()
    }

    /** Restricts manifest/route generation tokens to UUID-compatible ASCII path components. */
    static func isSafeGenerationIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45
        }
    }
}
