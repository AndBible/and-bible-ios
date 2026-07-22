// EpubInstalledMetadataSnapshot.swift -- nonmutating EPUB registration inventory

import Foundation

extension EpubReader {
    /**
     Reads published EPUB identities without migrating, rebuilding, leasing, or pruning generations.

     Normal reader inventory repairs legacy layouts and stale indexes before opening them. Backup
     preflight is observational and must not perform those writes, so it consumes only already
     published generation pointers whose immutable index metadata is internally consistent.

     - Parameters:
       - libraryRootURL: EPUB library root containing current-generation pointer files.
       - fileManager: Filesystem implementation used for read-only enumeration and containment.
     - Returns: Valid published EPUB metadata in deterministic source-filename order.
     - Side effects: Reads directory metadata, pointer JSON, and SQLite metadata in read-only mode.
     - Failure modes: Missing roots, legacy-only layouts, stale/malformed pointers, escaped
       generations, missing packages, and inconsistent indexes are skipped independently.
     */
    static func readOnlyInstalledEpubs(
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) -> [EpubInfo] {
        let requestedRoot = libraryRootURL.standardizedFileURL
        guard let requestedRootValues = try? requestedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        requestedRootValues.isDirectory == true,
        requestedRootValues.isSymbolicLink != true else {
            return []
        }
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        rootValues.isDirectory == true,
        rootValues.isSymbolicLink != true,
        let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return children.compactMap { pointerURL -> EpubInfo? in
            guard pointerURL.lastPathComponent.hasSuffix(generationManifestSuffix),
                  let pointerValues = try? pointerURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  pointerValues.isRegularFile == true,
                  pointerValues.isSymbolicLink != true else {
                return nil
            }

            let identifier = String(
                pointerURL.lastPathComponent.dropLast(generationManifestSuffix.count)
            )
            guard !identifier.isEmpty,
                  let manifest = generationManifest(
                    identifier: identifier,
                    libraryRootURL: root
                  ) else {
                return nil
            }
            let generationRoot = generationURL(
                identifier: identifier,
                generationIdentifier: manifest.generationIdentifier,
                libraryRootURL: root
            ).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard generationRoot.path.hasPrefix(rootPrefix) else { return nil }

            let packageURL = generationRoot.appendingPathComponent("package", isDirectory: true)
            let indexURL = generationRoot.appendingPathComponent("index.sqlite3")
            guard let packageValues = try? packageURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
            packageValues.isDirectory == true,
            packageValues.isSymbolicLink != true,
            let indexValues = try? indexURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            indexValues.isRegularFile == true,
            indexValues.isSymbolicLink != true,
            metadataValue(at: indexURL, key: "index_version") == indexVersion,
            metadataValue(at: indexURL, key: "generation") == manifest.generationIdentifier,
            let initials = nonEmptyMetadataValue(at: indexURL, key: "initials") else {
                return nil
            }

            let sourceFileName = nonEmptyMetadataValue(
                at: indexURL,
                key: "source_file_name"
            ) ?? identifier
            return EpubInfo(
                identifier: identifier,
                initials: initials,
                sourceFileName: sourceFileName,
                title: metadataValue(at: indexURL, key: "title") ?? "",
                author: metadataValue(at: indexURL, key: "author") ?? "",
                language: nonEmptyMetadataValue(at: indexURL, key: "language") ?? "en"
            )
        }
        .sorted {
            if $0.sourceFileName == $1.sourceFileName {
                return $0.identifier.utf8.lexicographicallyPrecedes($1.identifier.utf8)
            }
            return $0.sourceFileName.utf8.lexicographicallyPrecedes($1.sourceFileName.utf8)
        }
    }

    /** Returns one trimmed, non-empty SQLite metadata value. */
    private static func nonEmptyMetadataValue(at indexURL: URL, key: String) -> String? {
        guard let value = metadataValue(at: indexURL, key: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
