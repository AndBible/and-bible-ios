// EpubInstalledMetadataSnapshot.swift -- nonmutating EPUB registration inventory

import Foundation
import SwordKit

extension EpubReader {
    /**
     Captures every EPUB registration publishable by the iOS install and Android-backup restore
     boundaries without repairing or suppressing corrupt state.

     Unlike display inventory, admission must distinguish an absent library from an unreadable or
     inconsistent one. A missing root is a valid empty registry. Once the root exists, any pointer,
     generation, index, metadata, symlink, or legacy-layout problem throws so a caller can reject a
     new identity before mutation. Both production publishers derive a visible ASCII identifier via
     `stableIdentifier(forSourceFileName:)`, even for a leading-dot source name; hidden root entries
     are therefore reserved implementation state such as `.epub-generations` and remain excluded.

     - Parameters:
       - libraryRootURL: EPUB library root containing current-generation pointer files.
       - fileManager: Filesystem implementation used only for reads.
     - Returns: Valid current EPUB metadata in filesystem enumeration order among publishable
       pointer files, preserving Android's raw `File.listFiles()` first-owner replay.
     - Side effects: Reads directory metadata, JSON pointers, and SQLite metadata read-only; it does
       not create roots, migrate legacy installs, rebuild indexes, acquire leases, or prune files.
     - Throws: Filesystem, decoding, containment, legacy-layout, or SQLite metadata failures.
     */
    static func throwingReadOnlyInstalledEpubs(
        libraryRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> [EpubInfo] {
        // Admission invokes this while already holding the EPUB lock; the lock is recursive so the
        // same strict snapshot is also safe for standalone callers without creating a lock gap.
        libraryMutationLock.lock()
        defer { libraryMutationLock.unlock() }

        let requestedRoot = libraryRootURL.standardizedFileURL
        var requestedRootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: requestedRoot.path,
            isDirectory: &requestedRootIsDirectory
        ) else {
            return []
        }
        guard requestedRootIsDirectory.boolValue else {
            throw EpubError.invalidEpub("EPUB library root is not a directory")
        }
        let requestedAttributes = try fileManager.attributesOfItem(atPath: requestedRoot.path)
        guard requestedAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw EpubError.invalidEpub("EPUB library root is unsafe")
        }
        let requestedValues = try requestedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard requestedValues.isDirectory == true,
              requestedValues.isSymbolicLink != true else {
            throw EpubError.invalidEpub("EPUB library root is unsafe")
        }
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw EpubError.invalidEpub("EPUB library root is unsafe")
        }
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw EpubError.invalidEpub("EPUB library contains a symbolic link")
            }
            if values.isDirectory == true {
                throw EpubError.invalidEpub(
                    "EPUB library contains an unpublished or legacy package"
                )
            }
        }

        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [EpubInfo] = []
        for pointerURL in children
        where pointerURL.lastPathComponent.hasSuffix(generationManifestSuffix) {
            let pointerValues = try pointerURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard pointerValues.isRegularFile == true,
                  pointerValues.isSymbolicLink != true else {
                throw EpubError.invalidEpub("EPUB generation pointer is unsafe")
            }
            let identifier = String(
                pointerURL.lastPathComponent.dropLast(generationManifestSuffix.count)
            )
            guard !identifier.isEmpty,
                  identifier == URL(fileURLWithPath: identifier).lastPathComponent else {
                throw EpubError.invalidEpub("EPUB generation pointer has an unsafe identity")
            }
            let manifest = try JSONDecoder().decode(
                EpubGenerationManifest.self,
                from: Data(contentsOf: pointerURL)
            )
            guard manifest.schemaVersion == generationManifestVersion,
                  manifest.identifier == identifier,
                  isSafeGenerationIdentifier(manifest.generationIdentifier) else {
                throw EpubError.invalidEpub("EPUB generation pointer is inconsistent")
            }
            let generationRoot = generationURL(
                identifier: identifier,
                generationIdentifier: manifest.generationIdentifier,
                libraryRootURL: root
            ).resolvingSymlinksInPath().standardizedFileURL
            guard generationRoot.path.hasPrefix(rootPrefix) else {
                throw EpubError.invalidEpub("EPUB generation escapes the library root")
            }
            let packageURL = generationRoot.appendingPathComponent("package", isDirectory: true)
            let indexURL = generationRoot.appendingPathComponent("index.sqlite3")
            let packageValues = try packageURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let indexValues = try indexURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard packageValues.isDirectory == true,
                  packageValues.isSymbolicLink != true,
                  indexValues.isRegularFile == true,
                  indexValues.isSymbolicLink != true else {
                throw EpubError.invalidEpub("EPUB generation is incomplete or unsafe")
            }
            guard try throwingMetadataValue(at: indexURL, key: "index_version") == indexVersion,
                  try throwingMetadataValue(at: indexURL, key: "generation")
                    == manifest.generationIdentifier,
                  let initials = try throwingNonEmptyMetadataValue(
                    at: indexURL,
                    key: "initials"
                  ) else {
                throw EpubError.invalidEpub("EPUB generation metadata is inconsistent")
            }
            let sourceFileName = try throwingNonEmptyMetadataValue(
                at: indexURL,
                key: "source_file_name"
            ) ?? identifier
            result.append(EpubInfo(
                identifier: identifier,
                initials: initials,
                sourceFileName: sourceFileName,
                title: try throwingMetadataValue(at: indexURL, key: "title") ?? "",
                description: try throwingMetadataValue(at: indexURL, key: "description")
                    ?? sourceFileName,
                author: try throwingMetadataValue(at: indexURL, key: "author") ?? "",
                language: try throwingNonEmptyMetadataValue(at: indexURL, key: "language") ?? "en"
            ))
        }
        return result
    }

    /**
     Reads published EPUB identities without migrating, rebuilding, leasing, or pruning generations.

     Normal reader inventory repairs legacy layouts and stale indexes before opening them. Backup
     preflight is observational and must not perform those writes, so it consumes only already
     published generation pointers whose immutable index metadata is internally consistent.

     - Parameters:
       - libraryRootURL: EPUB library root containing current-generation pointer files.
       - fileManager: Filesystem implementation used for read-only enumeration and containment.
     - Returns: Valid published EPUB metadata in the filesystem enumeration order used by Android's
       raw `File.listFiles()` registration replay.
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
                description: metadataValue(at: indexURL, key: "description") ?? sourceFileName,
                author: metadataValue(at: indexURL, key: "author") ?? "",
                language: nonEmptyMetadataValue(at: indexURL, key: "language") ?? "en"
            )
        }
    }

    /** Returns one trimmed, non-empty SQLite metadata value. */
    private static func nonEmptyMetadataValue(at indexURL: URL, key: String) -> String? {
        guard let value = metadataValue(at: indexURL, key: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /** Reads and Java-trims one optional metadata value while preserving query failures. */
    private static func throwingNonEmptyMetadataValue(
        at indexURL: URL,
        key: String
    ) throws -> String? {
        guard let value = try throwingMetadataValue(at: indexURL, key: key) else { return nil }
        let trimmed = SwordJavaStringIdentity.trim(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
