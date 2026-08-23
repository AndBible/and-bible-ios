// AndroidModuleBackupRestoreAvailability.swift -- Transactional post-publish registration checks

import Foundation
import SwordKit

/**
 Makes restored Android families usable before the module-store journal can commit.

 File-backed SQLite and add-on registrations are validated from their live destinations. EPUB
 trees additionally publish immutable native generations; previous generations remain leased until
 the surrounding module transaction either commits or calls `rollback()`.
 */
internal final class AndroidModuleBackupRestoreAvailabilityTransaction {
    /// One EPUB pointer retained for rollback while a replacement generation is built.
    private struct EpubState {
        let relativeRoot: String
        let identifier: String
        let priorGeneration: EpubGenerationLocation?
        var publishedGenerationIdentifier: String?
    }

    /// Prepared generated registrations and expected archive identities.
    private let registration: AndroidModuleBackupPreparedRegistration

    /// Live Android-compatible module root.
    private let moduleDirectory: URL

    /// Native immutable EPUB library root.
    private let epubLibraryRootURL: URL

    /// Filesystem service used by validation and pointer rollback.
    private let fileManager: FileManager

    /// Retained EPUB state in archive registration order.
    private var epubStates: [EpubState] = []

    /// Whether prior EPUB leases have already been released.
    private var leasesReleased = false

    /**
     Creates an availability transaction and leases every previous EPUB generation.

     - Parameters:
       - registration: Prepared archive registrations whose files are about to publish.
       - moduleDirectory: Live module root used by generated configs and raw families.
       - epubLibraryRootURL: Optional isolated EPUB library; omission uses Documents/epub.
       - fileManager: Filesystem implementation used for validation and pointer restoration.
     - Side effects: Acquires leases on current EPUB generations so replacement publication cannot
       prune rollback state.
     - Failure modes: Missing current generations are represented as fresh installs; construction
       itself does not throw.
     - Important: The production caller constructs this value only after acquiring the canonical
       module-store coordinator and before the first exact-overlay mutation. Generation acquisition
       takes the recursive EPUB lock, preserving the global-coordinator-then-EPUB-lock order.
     */
    internal init(
        registration: AndroidModuleBackupPreparedRegistration,
        moduleDirectory: URL,
        epubLibraryRootURL: URL?,
        fileManager: FileManager
    ) {
        self.registration = registration
        self.moduleDirectory = moduleDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.epubLibraryRootURL = epubLibraryRootURL?.standardizedFileURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("epub", isDirectory: true)

        self.epubStates = registration.epubRelativeRoots.map { relativeRoot in
            let displayName = (relativeRoot as NSString).lastPathComponent
            let identifier = EpubReader.stableIdentifier(forSourceFileName: displayName)
            return EpubState(
                relativeRoot: relativeRoot,
                identifier: identifier,
                priorGeneration: EpubReader.acquireCurrentGeneration(
                    identifier: identifier,
                    libraryRootURL: self.epubLibraryRootURL
                ),
                publishedGenerationIdentifier: nil
            )
        }
    }

    deinit {
        releasePriorGenerationLeases()
    }

    /**
     Validates live registrations and atomically publishes every native EPUB generation.

     - Side effects: Opens live SQLite databases, reads bounded generated configs and prompt CSVs,
       creates native EPUB generations, and constructs a fresh `SwordManager` inventory snapshot.
     - Throws: Any validation, reader, EPUB, SWORD inventory, or filesystem failure. The surrounding
       exact-overlay publisher invokes `rollback()` before restoring module files.
     */
    internal func validatePublishedState() throws {
        try validateGeneratedConfigurationsAndBackings()

        for index in epubStates.indices {
            let sourceRoot = moduleDirectory.appendingPathComponent(
                epubStates[index].relativeRoot,
                isDirectory: true
            )
            let identifier = try EpubReader.installAndroidModuleBackup(
                epubDirectoryURL: sourceRoot,
                libraryRootURL: epubLibraryRootURL
            )
            guard identifier == epubStates[index].identifier,
                  let manifest = EpubReader.generationManifest(
                    identifier: identifier,
                    libraryRootURL: epubLibraryRootURL
                  ) else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Restored EPUB did not publish its expected native identity."
                )
            }
            epubStates[index].publishedGenerationIdentifier = manifest.generationIdentifier
        }

        let installedEpubInitials = Set(
            EpubReader.installedEpubs(libraryRootURL: epubLibraryRootURL).map {
                SQLiteDocumentIdentity($0.initials)
            }
        )
        for candidate in registration.candidates where candidate.family == .epub {
            guard installedEpubInitials.contains(SQLiteDocumentIdentity(candidate.initials)) else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Restored EPUB \(candidate.initials) is not available after registration."
                )
            }
        }

        guard let manager = SwordManager(modulePath: moduleDirectory.path) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Restored module store could not be opened after registration."
            )
        }
        let installedIdentities = Set(manager.installedModules().map {
            SQLiteDocumentIdentity($0.name)
        })
        for content in registration.archiveContent {
            let identity = SQLiteDocumentIdentity(content.initials)
            switch content.family {
            case .swordConfiguration, .myBible, .mySword, .eSword:
                guard installedIdentities.contains(identity) else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Restored module \(content.initials) is not available after registration."
                    )
                }
            case .ttf, .background, .prompts:
                guard manager.module(named: content.initials) != nil else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Restored add-on \(content.initials) is not available after registration."
                    )
                }
            case .epub:
                guard installedEpubInitials.contains(identity) else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Restored EPUB \(content.initials) is not available after registration."
                    )
                }
            case .swordPayload:
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Archive registration contains a payload without its SWORD configuration."
                )
            }
        }

        let expectedPromptIdentities = Set(
            registration.candidates
                .filter { $0.family == .prompts }
                .map { SQLiteDocumentIdentity($0.initials) }
        )
        if !expectedPromptIdentities.isEmpty {
            let loadedPromptIdentities = Set(
                try SwordPromptPackProvider(swordManager: manager).loadPromptPacks().map {
                    SQLiteDocumentIdentity($0.moduleName)
                }
            )
            guard expectedPromptIdentities.isSubset(of: loadedPromptIdentities) else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "One or more restored prompt packs are not available after registration."
                )
            }
        }
    }

    /**
     Restores every previous EPUB pointer and then releases retained generation leases.

     - Side effects: Atomically rewrites or removes stable EPUB pointer files, prunes unleased new
       generations, and releases prior-generation leases.
     - Throws: A combined filesystem error after attempting every pointer inverse. The method is
       idempotent and safe when validation failed before any EPUB publication.
     */
    internal func rollback() throws {
        var failures: [String] = []
        EpubReader.libraryMutationLock.lock()
        for state in epubStates.reversed() where state.publishedGenerationIdentifier != nil {
            do {
                let pointerURL = EpubReader.generationManifestURL(
                    identifier: state.identifier,
                    libraryRootURL: epubLibraryRootURL
                )
                if let prior = state.priorGeneration {
                    let manifest = EpubGenerationManifest(
                        schemaVersion: EpubReader.generationManifestVersion,
                        identifier: state.identifier,
                        generationIdentifier: prior.generationIdentifier
                    )
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(manifest).write(to: pointerURL, options: .atomic)
                } else if fileManager.fileExists(atPath: pointerURL.path) {
                    try fileManager.removeItem(at: pointerURL)
                }
                EpubReader.pruneGenerations(
                    identifier: state.identifier,
                    libraryRootURL: epubLibraryRootURL,
                    fileManager: fileManager
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        EpubReader.libraryMutationLock.unlock()
        releasePriorGenerationLeases()
        guard failures.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "EPUB registration rollback failed: \(failures.joined(separator: "; "))."
            )
        }
    }

    /** Releases prior-generation leases after the surrounding module journal commits. */
    internal func complete() {
        releasePriorGenerationLeases()
    }
}

/** Live generated-config, payload, and prompt-pack validation. */
private extension AndroidModuleBackupRestoreAvailabilityTransaction {
    /// Maximum generated config bytes materialized during post-publish validation.
    static let maximumGeneratedConfigurationByteCount = 64 * 1_024

    /// Maximum Android prompt-pack bytes accepted by production discovery.
    static let maximumPromptPackByteCount = 8 * 1_024 * 1_024

    /** Validates every generated config and exact backing payload from its live destination. */
    func validateGeneratedConfigurationsAndBackings() throws {
        for candidate in registration.candidates {
            let configURL = moduleDirectory.appendingPathComponent(
                candidate.configurationRelativePath
            )
            let configSource = try ZipArchiveWriterPinnedFileSource(fileURL: configURL)
            let configData = try configSource.boundedData(
                maximumByteCount: Self.maximumGeneratedConfigurationByteCount
            )
            guard let config = String(data: configData, encoding: .utf8),
                  config.contains("[\(candidate.initials)]"),
                  config.contains("AndBibleIOSGeneratedRegistration=true"),
                  config.contains("AndBibleIOSRegistrationPath=\(candidate.relativePath)") else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Generated registration is not readable for \(candidate.initials)."
                )
            }

            let payloadURL = moduleDirectory.appendingPathComponent(candidate.relativePath)
            switch candidate.family {
            case .myBible:
                let metadata = try MyBibleReader(fileURL: payloadURL).metadata
                try validateDatabaseIdentity(metadata.initials, candidate: candidate)
            case .mySword:
                let metadata = try MySwordReader(fileURL: payloadURL).metadata
                try validateDatabaseIdentity(metadata.initials, candidate: candidate)
            case .eSword:
                let metadata = try ESwordReader(fileURL: payloadURL).metadata
                try validateDatabaseIdentity(metadata.initials, candidate: candidate)
            case .epub:
                let values = try payloadURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Restored EPUB root is not a real directory: \(candidate.relativePath)."
                    )
                }
            case .ttf, .background:
                let values = try payloadURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isReadableKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isReadable != false,
                      values.isSymbolicLink != true else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Restored resource is not readable: \(candidate.relativePath)."
                    )
                }
            case .prompts:
                let source = try ZipArchiveWriterPinnedFileSource(fileURL: payloadURL)
                let data = try source.boundedData(
                    maximumByteCount: Self.maximumPromptPackByteCount
                )
                _ = try PromptCSVParser.parse(data: data)
            case .swordConfiguration, .swordPayload:
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Unexpected generated registration family \(candidate.family.rawValue)."
                )
            }
        }
    }

    /** Checks exact Android SQLite initials after reopening the published database. */
    func validateDatabaseIdentity(
        _ initials: String,
        candidate: AndroidModuleBackupRegistrationCandidate
    ) throws {
        guard SQLiteDocumentIdentity(initials) == SQLiteDocumentIdentity(candidate.initials) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Published database identity \(initials) differs from \(candidate.initials)."
            )
        }
    }

    /** Releases every prior-generation lease exactly once. */
    func releasePriorGenerationLeases() {
        guard !leasesReleased else { return }
        leasesReleased = true
        for state in epubStates {
            if let prior = state.priorGeneration {
                EpubReader.releaseGeneration(prior, libraryRootURL: epubLibraryRootURL)
            }
        }
    }
}
