// RemoteSyncReadingPlanDefinitionStore.swift - Custom reading-plan definition integrity

import Darwin
import CryptoKit
import Foundation
import SwiftData

/**
 Exact Android-readable contents of one user reading-plan `.properties` file.

 The stable plan code is the filename stem. `propertiesData` remains byte-for-byte unchanged so an
 archive or local import does not normalize escapes, comments, continuations, or the ISO-8859-1
 byte interpretation used by `java.util.Properties.load(InputStream)`.
 */
public struct RemoteSyncReadingPlanDefinition: Codable, Equatable, Sendable {
    /// Exact filename stem used as Android's reading-plan identity.
    public let planCode: String

    /// Original `.properties` file bytes.
    public let propertiesData: Data

    /** Creates one exact-byte custom reading-plan definition without performing validation. */
    public init(planCode: String, propertiesData: Data) {
        self.planCode = planCode
        self.propertiesData = propertiesData
    }
}

/** Fail-visible custom-definition validation and local publication failures. */
public enum RemoteSyncReadingPlanDefinitionError: Error, Equatable, Sendable {
    /// A plan code cannot safely or faithfully become an Android `.properties` filename.
    case invalidPlanCode(String)

    /// A custom identity collides with one of Android's bundled reading plans.
    case bundledPlanCodeCollision(String)

    /// A local definition file could not be read for validation or publication.
    case unreadableLocalDefinition(String)

    /// Definition bytes do not form an Android-usable plan with at least one positive day.
    case malformedProperties(String)

    /// A numeric Java-properties key is outside Android's signed `Int32` domain.
    case dayNumberOutOfRange(String)

    /// A definition exceeds the bounded payload accepted from an untrusted source.
    case definitionTooLarge(String)

    /// A local definition directory contains more files than the bounded reader accepts.
    case tooManyDefinitions(Int)

    /// Aggregate local definition bytes exceed the bounded reader contract.
    case aggregateDefinitionsTooLarge(Int)

    /// One local definition generation contains the same stable plan code more than once.
    case duplicateDefinition(String)

    /// Two Android identities resolve to the same canonical destination on the local filesystem.
    case filesystemIdentityCollision(String)

    /// Different bytes require a model-aware mutation instead of the file-only compatibility API.
    case coordinatedMutationRequired(String)

    /// A pending generation must be recovered with its graph-colocated commit marker first.
    case recoveryRequired

    /// Definition files could not be staged or published.
    case installationFailed(String)

    /// A failed publication could not restore the prior filesystem generation.
    case rollbackFailed(String)

    /// Startup recovery found an incomplete or contradictory publication journal.
    case recoveryFailed(String)

    /// The graph-colocated publication marker is missing, duplicated, or contradictory.
    case invalidPublicationState
}

/**
 Validates exact custom-plan bytes and publishes complete definition generations transactionally.

 Files are staged beside the live `jsword/readingplan` directory and published by directory rename.
 A durable journal records each rename phase. The same SwiftData transaction that publishes plan,
 status, fingerprint, and conflict-log state stores the generation identifier; startup recovery
 keeps the new directory only when that commit marker exists, otherwise it restores the backup.

 Definitions remain device-local, matching Android's `jsword/readingplan` behavior. Remote sync and
 Android database backups carry only Android's Room tables; this store never serializes definition
 bytes into those databases.

 - Important: A process-wide recursive lock serializes every store instance targeting definition
   storage. Cross-process access is outside the app's supported mutation model.
 */
final class RemoteSyncReadingPlanDefinitionStore {
    /// Maximum bytes accepted for one Java-properties definition.
    static let maximumDefinitionByteCount = 4 * 1_024 * 1_024

    /// Maximum custom definitions accepted in one local generation.
    static let maximumDefinitionCount = 256

    /// Maximum aggregate exact bytes accepted across one definition generation.
    static let maximumAggregateDefinitionByteCount = 16 * 1_024 * 1_024

    /// Maximum UTF-8 bytes accepted for one Android filename-stem identity.
    static let maximumPlanCodeByteCount = 128

    /// Serializes mutation and recovery across independent service instances.
    private static let mutationLock = NSRecursiveLock()

    /// Live directories currently published inside the owning settings transaction.
    private static var activePublicationPaths = Set<String>()

    /// Filesystem publication phase persisted after each durable rename boundary.
    private enum PublicationPhase: String, Codable {
        /// Staging may exist, while the live directory is still untouched.
        case prepared

        /// The old directory has moved to backup and staging has not yet become live.
        case oldMoved

        /// The staged generation is live and awaits graph/settings commit confirmation.
        case newPublished
    }

    /// Durable filesystem journal used to recover a process termination at any rename boundary.
    private struct PublicationJournal: Codable, Equatable {
        let identifier: String
        let stagingName: String
        let backupName: String
        let hadLiveDirectory: Bool
        let previousDefinitionDigest: String
        let publishedDefinitionDigest: String
        var phase: PublicationPhase
    }

    /// Durable boundaries exposed only for process-termination behavior tests.
    enum PublicationBoundary: Equatable {
        case prepared
        case oldMoved
        case newPublished
        case graphCommitted
    }

    /// Destination equivalent to Android's `jsword/readingplan` directory.
    private let userPlanDirectory: URL

    /// Filesystem implementation used for discovery, staging, publication, and recovery.
    private let fileManager: FileManager

    /// Optional termination hook invoked after each synchronized durable publication boundary.
    private let publicationCheckpoint: (PublicationBoundary) throws -> Void

    /**
     Creates a definition store for one device-local reading-plan directory.

     - Parameters:
       - userPlanDirectory: Directory containing user `.properties` files.
       - fileManager: Filesystem implementation used for reads and writes.
     - Side effects: none until a read, mutation, or recovery is requested.
     - Failure modes: This initializer cannot fail.
     */
    init(
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        publicationCheckpoint: @escaping (PublicationBoundary) throws -> Void = { _ in }
    ) {
        self.userPlanDirectory = userPlanDirectory
        self.fileManager = fileManager
        self.publicationCheckpoint = publicationCheckpoint
    }

    /**
     Reads one regular definition file without allocating beyond the accepted payload bound.

     - Parameter url: Local definition file to read exactly.
     - Returns: Original bytes with no text decoding or normalization.
     - Side effects: Opens and closes one read handle.
     - Throws: Read/type errors or `definitionTooLarge` before an unbounded allocation can occur.
     */
    static func readBoundedDefinitionData(from url: URL) throws -> Data {
        let planCode = androidPlanCode(forFileName: url.lastPathComponent)
            ?? url.lastPathComponent
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(planCode)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(planCode)
        }
        guard status.st_size <= off_t(maximumDefinitionByteCount) else {
            throw RemoteSyncReadingPlanDefinitionError.definitionTooLarge(planCode)
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount >= 0 else {
                throw RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(planCode)
            }
            guard readCount > 0 else { break }
            guard data.count <= maximumDefinitionByteCount - readCount else {
                throw RemoteSyncReadingPlanDefinitionError.definitionTooLarge(planCode)
            }
            data.append(buffer, count: readCount)
        }
        return data
    }

    /**
     Validates a source filename and exact Java-properties bytes for local import.

     - Parameters:
       - fileName: Exact basename ending in lowercase `.properties`.
       - propertiesData: Original bytes without transcoding.
     - Returns: Validated stable code and exact bytes.
     - Side effects: none.
     - Throws: Unsafe filename, bundled collision, size, syntax, or day-range errors.
     */
    func validatedDefinition(
        fileName: String,
        propertiesData: Data
    ) throws -> RemoteSyncReadingPlanDefinition {
        let sourceName = URL(fileURLWithPath: fileName).lastPathComponent
        guard sourceName == fileName,
              !fileName.contains("\\"),
              sourceName.hasSuffix(".properties") else {
            throw ReadingPlanImportError.invalidFileName
        }
        guard let planCode = Self.androidPlanCode(forFileName: sourceName) else {
            throw ReadingPlanImportError.invalidFileName
        }
        let definition = RemoteSyncReadingPlanDefinition(
            planCode: planCode,
            propertiesData: propertiesData
        )
        do {
            try Self.validate(definition)
        } catch RemoteSyncReadingPlanDefinitionError.invalidPlanCode(_) {
            throw ReadingPlanImportError.invalidFileName
        } catch RemoteSyncReadingPlanDefinitionError.bundledPlanCodeCollision(_) {
            throw ReadingPlanImportError.bundledPlanCodeCollision
        } catch RemoteSyncReadingPlanDefinitionError.malformedProperties(_) {
            throw ReadingPlanImportError.invalidProperties
        }
        return definition
    }

    /**
     Installs a definition only when no graph-aware edit is required.

     New unreferenced files use an atomic single-file write. Identical bytes are idempotent. A
     different existing payload fails so callers cannot split definition edits from plan/status
     reconstruction.

     - Parameter definition: Validated custom definition.
     - Side effects: May create the user directory and one definition file.
     - Throws: Validation, recovery-required, coordinated-mutation, or filesystem failures.
     */
    func installUnreferencedDefinition(_ definition: RemoteSyncReadingPlanDefinition) throws {
        try synchronized {
            try Self.validate(definition)
            guard !fileManager.fileExists(atPath: journalURL.path) else {
                throw RemoteSyncReadingPlanDefinitionError.recoveryRequired
            }
            try rejectFilesystemIdentityCollision(
                for: definition.planCode,
                allowingExactCanonicalName: true
            )
            let destination = definitionURL(for: definition.planCode)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try Self.readBoundedDefinitionData(from: destination)
                guard existing == definition.propertiesData else {
                    throw RemoteSyncReadingPlanDefinitionError.coordinatedMutationRequired(
                        definition.planCode
                    )
                }
                return
            }
            do {
                try fileManager.createDirectory(
                    at: userPlanDirectory,
                    withIntermediateDirectories: true
                )
                try definition.propertiesData.write(to: destination, options: [.atomic])
                try synchronizeFile(at: destination)
                try synchronizeDirectory(at: userPlanDirectory)
            } catch let error as RemoteSyncReadingPlanDefinitionError {
                throw error
            } catch {
                throw RemoteSyncReadingPlanDefinitionError.installationFailed(
                    definition.planCode
                )
            }
        }
    }

    /**
     Reads every local custom definition as exact bytes.

     - Returns: Valid definitions ordered by exact Android plan code.
     - Side effects: Lists and reads regular `.properties` files.
     - Throws: Recovery-required, read, duplicate, collision, count, aggregate-size, or content errors.
     */
    func localDefinitions() throws -> [RemoteSyncReadingPlanDefinition] {
        try synchronized {
            guard !fileManager.fileExists(atPath: journalURL.path)
                || Self.activePublicationPaths.contains(publicationPath) else {
                throw RemoteSyncReadingPlanDefinitionError.recoveryRequired
            }
            return try definitions(at: userPlanDirectory)
        }
    }

    /**
     Recovers interrupted publication before a snapshot unless called reentrantly by its transaction.

     - Parameter settingsStore: Store containing the durable generation commit marker.
     - Side effects: May finalize or roll back an interrupted definition-directory publication.
     - Throws: Recovery or filesystem failures when journal state is contradictory.
     */
    func prepareForSnapshot(settingsStore: SettingsStore) throws {
        try synchronized {
            guard !Self.activePublicationPaths.contains(publicationPath) else { return }
            try recoverPendingPublicationLocked(settingsStore: settingsStore)
        }
    }

    /**
     Recovers an interrupted definition publication using its transaction commit marker.

     - Parameter settingsStore: Store containing the generation identifier committed with the graph.
     - Side effects: Finalizes the new directory or restores the backup, then removes journal debris.
     - Throws: Invalid journal, missing required generation, or filesystem recovery errors.
     */
    func recoverPendingPublication(settingsStore: SettingsStore) throws {
        try synchronized {
            try recoverPendingPublicationLocked(settingsStore: settingsStore)
        }
    }

    /**
     Publishes a local custom-definition import together with its plan graph and progress state.

     - Parameters:
       - definition: Validated exact-byte local definition.
       - modelContext: Clean context containing graph and settings models.
       - settingsStore: Settings store bound to `modelContext`.
       - operation: Graph/status/journal mutation; receives whether definition bytes changed.
     - Returns: Value returned by `operation` after one durable commit.
     - Side effects: May replace the complete definition directory and commits supplied mutations.
     - Throws: Validation, recovery, filesystem, context, operation, or commit failures.
     */
    func withPublishingLocalDefinition<Result>(
        _ definition: RemoteSyncReadingPlanDefinition,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        operation: (Bool) throws -> Result
    ) throws -> Result {
        try synchronized {
            try recoverPendingPublicationLocked(settingsStore: settingsStore)
            try Self.validate(definition)
            let durableGraphRecovery = try RemoteSyncReadingPlanRestoreService.durableGraphRecovery(
                from: modelContext
            )
            let current = try definitionMap()
            var target = current
            let changed = current[definition.planCode] != definition.propertiesData
            target[definition.planCode] = definition.propertiesData
            return try publish(
                current: current,
                target: target,
                modelContext: modelContext,
                settingsStore: settingsStore,
                durableGraphRecovery: durableGraphRecovery
            ) {
                try operation(changed)
            }
        }
    }

    /**
     Publishes one complete target generation and binds it to the caller's SwiftData transaction.

     - Parameters:
       - current: Exact current definition map.
       - target: Exact target definition map.
       - modelContext: Clean graph/settings context.
       - settingsStore: Settings store bound to `modelContext`.
       - durableGraphRecovery: Optional compensation for graph rows in a separate configuration.
       - operation: Caller state mutation to commit with the generation marker.
     - Returns: Value returned by `operation`.
     - Side effects: Stages/renames directories, commits graph/settings once, and removes journal data.
     - Throws: Validation, staging, context, operation, commit, or rollback failures.
     */
    private func publish<Result>(
        current: [String: Data],
        target: [String: Data],
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        durableGraphRecovery: ((ModelContainer) throws -> Void)? = nil,
        operation: () throws -> Result
    ) throws -> Result {
        try Self.validateUnique(target.map {
            RemoteSyncReadingPlanDefinition(planCode: $0.key, propertiesData: $0.value)
        })

        guard current != target else {
            return try settingsStore.performAtomicBatch(
                in: modelContext,
                durableRecovery: durableGraphRecovery
            ) {
                let value = try operation()
                guard let state = try publicationState(
                    in: modelContext,
                    createIfMissing: true
                ) else {
                    throw RemoteSyncReadingPlanDefinitionError.invalidPublicationState
                }
                let generation = state.committedGeneration
                    ?? "baseline-\(Self.definitionGenerationDigest(target))"
                state.committedGeneration = generation
                return value
            }
        }

        let identifier = UUID().uuidString.lowercased()
        var journal = PublicationJournal(
            identifier: identifier,
            stagingName: ".\(userPlanDirectory.lastPathComponent).definition-staging-\(identifier)",
            backupName: ".\(userPlanDirectory.lastPathComponent).definition-backup-\(identifier)",
            hadLiveDirectory: fileManager.fileExists(atPath: userPlanDirectory.path),
            previousDefinitionDigest: Self.definitionGenerationDigest(current),
            publishedDefinitionDigest: Self.definitionGenerationDigest(target),
            phase: .prepared
        )

        do {
            try prepareStagingDirectory(target: target, journal: journal)
            try writeJournal(journal)
        } catch {
            try? removeValidatedPublicationArtifact(stagingURL(for: journal), journal: journal)
            try? removeValidatedPublicationArtifact(journalURL, journal: journal)
            throw error
        }
        try publicationCheckpoint(.prepared)

        do {
            if journal.hadLiveDirectory {
                try fileManager.moveItem(at: userPlanDirectory, to: backupURL(for: journal))
                try synchronizeDirectory(at: userPlanDirectory.deletingLastPathComponent())
            }
            journal.phase = .oldMoved
            try writeJournal(journal)
        } catch {
            try recoverUncommittedPublication(journal)
            throw error
        }
        try publicationCheckpoint(.oldMoved)

        do {
            try fileManager.moveItem(at: stagingURL(for: journal), to: userPlanDirectory)
            try synchronizeDirectory(at: userPlanDirectory.deletingLastPathComponent())
            journal.phase = .newPublished
            try writeJournal(journal)
        } catch {
            try recoverUncommittedPublication(journal)
            throw error
        }
        try publicationCheckpoint(.newPublished)

        let result: Result
        do {
            Self.activePublicationPaths.insert(publicationPath)
            defer { Self.activePublicationPaths.remove(publicationPath) }
            result = try settingsStore.performAtomicBatch(
                in: modelContext,
                durableRecovery: durableGraphRecovery
            ) {
                let value = try operation()
                guard let state = try publicationState(
                    in: modelContext,
                    createIfMissing: true
                ) else {
                    throw RemoteSyncReadingPlanDefinitionError.invalidPublicationState
                }
                state.committedGeneration = journal.identifier
                return value
            }
        } catch let commitError {
            let graphGenerationCommitted: Bool
            do {
                graphGenerationCommitted = try isPublicationGenerationCommitted(
                    identifier,
                    in: modelContext.container
                )
            } catch {
                // The durable marker is authoritative. Leave the journal and both recoverable
                // generations intact when it cannot be read safely.
                throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(identifier)
            }

            do {
                if graphGenerationCommitted {
                    guard journal.phase == .newPublished,
                          try definitionDigest(at: userPlanDirectory)
                            == journal.publishedDefinitionDigest else {
                        throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(identifier)
                    }
                    try finalizeCommittedPublication(journal)
                } else {
                    try recoverUncommittedPublication(journal)
                }
            } catch {
                if graphGenerationCommitted {
                    throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(identifier)
                }
                throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(identifier)
            }
            throw commitError
        }
        try publicationCheckpoint(.graphCommitted)

        do {
            try finalizeCommittedPublication(journal)
        } catch {
            // The graph and generation marker are already durable. Leave the journal so startup
            // recovery can finish cleanup without ever restoring the obsolete definition bytes.
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(identifier)
        }
        return result
    }

    /**
     Resolves an interrupted publication according to its graph-colocated commit identifier.

     - Parameter settingsStore: Store exposing the exact context that owns the plan graph marker.
     - Side effects: Finalizes committed files or restores the pre-publication directory.
     - Throws: Journal decoding or contradictory filesystem-state errors.
     */
    private func recoverPendingPublicationLocked(settingsStore: SettingsStore) throws {
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let journal: PublicationJournal
        do {
            let data = try Self.readBoundedRegularFile(
                at: journalURL,
                maximumByteCount: 64 * 1_024
            )
            journal = try JSONDecoder().decode(PublicationJournal.self, from: data)
            try validateJournal(journal)
        } catch {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(
                userPlanDirectory.lastPathComponent
            )
        }

        let state = try publicationState(
            in: settingsStore.persistenceModelContext,
            createIfMissing: false
        )
        if state?.committedGeneration == journal.identifier {
            guard journal.phase == .newPublished,
                  try definitionDigest(at: userPlanDirectory)
                    == journal.publishedDefinitionDigest else {
                throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(journal.identifier)
            }
            try finalizeCommittedPublication(journal)
        } else {
            do {
                try recoverUncommittedPublication(journal)
            } catch {
                throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(journal.identifier)
            }
        }
    }

    /** Stages a complete definition generation while preserving unrelated directory entries. */
    private func prepareStagingDirectory(
        target: [String: Data],
        journal: PublicationJournal
    ) throws {
        let stagingURL = stagingURL(for: journal)
        let parent = userPlanDirectory.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: stagingURL.path) {
                try removeValidatedPublicationArtifact(stagingURL, journal: journal)
            }
            if journal.hadLiveDirectory {
                let values = try userPlanDirectory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw RemoteSyncReadingPlanDefinitionError.installationFailed(
                        userPlanDirectory.lastPathComponent
                    )
                }
                try fileManager.copyItem(at: userPlanDirectory, to: stagingURL)
            } else {
                try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            }

            let stagedFiles = try fileManager.contentsOfDirectory(
                at: stagingURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            for url in stagedFiles where Self.androidPlanCode(forFileName: url.lastPathComponent) != nil {
                try fileManager.removeItem(at: url)
            }
            for (planCode, data) in target.sorted(by: { $0.key < $1.key }) {
                let destination = stagingURL
                    .appendingPathComponent(planCode, isDirectory: false)
                    .appendingPathExtension("properties")
                try data.write(to: destination, options: [.atomic])
                try synchronizeFile(at: destination)
            }
            try synchronizeDirectory(at: stagingURL)
            guard try definitionDigest(at: stagingURL) == journal.publishedDefinitionDigest else {
                throw RemoteSyncReadingPlanDefinitionError.installationFailed(journal.identifier)
            }
            try synchronizeDirectory(at: parent)
        } catch let error as RemoteSyncReadingPlanDefinitionError {
            throw error
        } catch {
            throw RemoteSyncReadingPlanDefinitionError.installationFailed(
                target.keys.sorted().first ?? userPlanDirectory.lastPathComponent
            )
        }
    }

    /** Writes and synchronizes the publication journal after one rename phase. */
    private func writeJournal(_ journal: PublicationJournal) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(journal).write(to: journalURL, options: [.atomic])
            try synchronizeFile(at: journalURL)
            try synchronizeDirectory(at: journalURL.deletingLastPathComponent())
        } catch {
            throw RemoteSyncReadingPlanDefinitionError.installationFailed(journal.identifier)
        }
    }

    /** Removes backup, staging, and journal artifacts after a committed generation is confirmed. */
    private func finalizeCommittedPublication(_ journal: PublicationJournal) throws {
        try validateJournal(journal)
        let backupURL = backupURL(for: journal)
        let stagingURL = stagingURL(for: journal)
        let parentURL = userPlanDirectory.deletingLastPathComponent()
        if fileManager.fileExists(atPath: backupURL.path) {
            try removeValidatedPublicationArtifact(backupURL, journal: journal)
        }
        if fileManager.fileExists(atPath: stagingURL.path) {
            try removeValidatedPublicationArtifact(stagingURL, journal: journal)
        }
        try synchronizeDirectory(at: parentURL)
        if fileManager.fileExists(atPath: journalURL.path) {
            try removeValidatedPublicationArtifact(journalURL, journal: journal)
        }
        try synchronizeDirectory(at: parentURL)
    }

    /** Restores the pre-publication directory for every recoverable uncommitted filesystem state. */
    private func recoverUncommittedPublication(_ journal: PublicationJournal) throws {
        try validateJournal(journal)
        let backupURL = backupURL(for: journal)
        let stagingURL = stagingURL(for: journal)
        let parentURL = userPlanDirectory.deletingLastPathComponent()
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        let hasLiveDirectory = fileManager.fileExists(atPath: userPlanDirectory.path)

        if journal.hadLiveDirectory {
            if hasBackup {
                guard try definitionDigest(at: backupURL)
                    == journal.previousDefinitionDigest else {
                    throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
                }
                if hasLiveDirectory {
                    let liveDigest = try definitionDigest(at: userPlanDirectory)
                    guard liveDigest == journal.publishedDefinitionDigest
                            || liveDigest == journal.previousDefinitionDigest else {
                        throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
                    }
                    try removeLiveDirectoryForRecovery(journal: journal)
                    try synchronizeDirectory(at: parentURL)
                }
                try fileManager.moveItem(at: backupURL, to: userPlanDirectory)
                try synchronizeDirectory(at: parentURL)
            } else {
                guard hasLiveDirectory,
                      try definitionDigest(at: userPlanDirectory)
                        == journal.previousDefinitionDigest else {
                    throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
                }
            }
        } else {
            guard !hasBackup else {
                throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
            }
            if hasLiveDirectory {
                guard try definitionDigest(at: userPlanDirectory)
                    == journal.publishedDefinitionDigest else {
                    throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
                }
                try removeLiveDirectoryForRecovery(journal: journal)
                try synchronizeDirectory(at: parentURL)
            }
        }
        if fileManager.fileExists(atPath: stagingURL.path) {
            try removeValidatedPublicationArtifact(stagingURL, journal: journal)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try removeValidatedPublicationArtifact(backupURL, journal: journal)
        }
        try synchronizeDirectory(at: parentURL)
        if fileManager.fileExists(atPath: journalURL.path) {
            try removeValidatedPublicationArtifact(journalURL, journal: journal)
        }
        try synchronizeDirectory(at: parentURL)
    }

    /** Reads and validates every exact-byte definition in the configured live directory. */
    private func definitionMap() throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try definitions(at: userPlanDirectory).map {
            ($0.planCode, $0.propertiesData)
        })
    }

    /// Standardized identity used to recognize nested snapshots of this publication target.
    private var publicationPath: String {
        userPlanDirectory.standardizedFileURL.path
    }

    /** Reads a complete bounded definition generation from one directory. */
    private func definitions(at directory: URL) throws -> [RemoteSyncReadingPlanDefinition] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        var directoryStatus = stat()
        guard Darwin.lstat(directory.path, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(
                directory.lastPathComponent
            )
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw RemoteSyncReadingPlanDefinitionError.unreadableLocalDefinition(
                directory.lastPathComponent
            )
        }

        let propertyURLs = urls.filter {
            Self.androidPlanCode(forFileName: $0.lastPathComponent) != nil
        }
        guard propertyURLs.count <= Self.maximumDefinitionCount else {
            throw RemoteSyncReadingPlanDefinitionError.tooManyDefinitions(propertyURLs.count)
        }
        var definitions: [RemoteSyncReadingPlanDefinition] = []
        var filesystemIdentities = Set<String>()
        var aggregateByteCount = 0
        for url in propertyURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let planCode = Self.androidPlanCode(forFileName: url.lastPathComponent) else {
                continue
            }
            let filesystemIdentity = Self.filesystemIdentity(for: planCode)
            guard filesystemIdentities.insert(filesystemIdentity).inserted else {
                throw RemoteSyncReadingPlanDefinitionError.filesystemIdentityCollision(planCode)
            }
            let data = try Self.readBoundedDefinitionData(from: url)
            let (nextAggregate, overflow) = aggregateByteCount.addingReportingOverflow(data.count)
            guard !overflow,
                  nextAggregate <= Self.maximumAggregateDefinitionByteCount else {
                throw RemoteSyncReadingPlanDefinitionError.aggregateDefinitionsTooLarge(
                    overflow ? Int.max : nextAggregate
                )
            }
            aggregateByteCount = nextAggregate
            definitions.append(
                RemoteSyncReadingPlanDefinition(planCode: planCode, propertiesData: data)
            )
        }
        try Self.validateUnique(definitions)
        return definitions
    }

    /** Fetches the unique graph-colocated state row for this exact definition directory. */
    private func publicationState(
        in modelContext: ModelContext,
        createIfMissing: Bool
    ) throws -> ReadingPlanDefinitionPublicationState? {
        let storageKey = publicationStorageKey
        let rows = try modelContext.fetch(FetchDescriptor<ReadingPlanDefinitionPublicationState>())
            .filter { $0.storageKey == storageKey }
        guard rows.count <= 1 else {
            throw RemoteSyncReadingPlanDefinitionError.invalidPublicationState
        }
        if let row = rows.first { return row }
        guard createIfMissing else { return nil }
        let row = ReadingPlanDefinitionPublicationState(storageKey: storageKey)
        modelContext.insert(row)
        return row
    }

    /** Reads the graph-colocated publication marker through a fresh durable context. */
    private func isPublicationGenerationCommitted(
        _ generation: String,
        in container: ModelContainer
    ) throws -> Bool {
        let durableContext = ModelContext(container)
        durableContext.autosaveEnabled = false
        return try publicationState(
            in: durableContext,
            createIfMissing: false
        )?.committedGeneration == generation
    }

    /** Returns Android's exact filename identity using `String.replace` semantics. */
    private static func androidPlanCode(forFileName fileName: String) -> String? {
        guard fileName.hasSuffix(".properties") else { return nil }
        return fileName.replacingOccurrences(of: ".properties", with: "")
    }

    /** Canonical case-insensitive key matching the default Apple filesystem collision domain. */
    private static func filesystemIdentity(for planCode: String) -> String {
        planCode.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /** Rejects an import whose canonical destination aliases another Android definition identity. */
    private func rejectFilesystemIdentityCollision(
        for planCode: String,
        allowingExactCanonicalName: Bool
    ) throws {
        guard fileManager.fileExists(atPath: userPlanDirectory.path) else { return }
        let requestedIdentity = Self.filesystemIdentity(for: planCode)
        let requestedName = "\(planCode).properties"
        let names = try fileManager.contentsOfDirectory(atPath: userPlanDirectory.path)
        for name in names {
            guard let existingCode = Self.androidPlanCode(forFileName: name),
                  Self.filesystemIdentity(for: existingCode) == requestedIdentity else {
                continue
            }
            if allowingExactCanonicalName && name == requestedName { continue }
            throw RemoteSyncReadingPlanDefinitionError.filesystemIdentityCollision(planCode)
        }
    }

    /** Stable row key for one device-local definition-directory path. */
    private var publicationStorageKey: String {
        Self.contentDigest(Data(publicationPath.utf8))
    }

    /** Stable SHA-256 digest of exact definition bytes. */
    private static func contentDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /** Stable digest of sorted Android identities and their exact content digests. */
    private static func definitionGenerationDigest(_ definitions: [String: Data]) -> String {
        var payload = Data()
        for (planCode, data) in definitions.sorted(by: { $0.key < $1.key }) {
            let code = Data(planCode.utf8)
            var codeLength = UInt64(code.count).bigEndian
            withUnsafeBytes(of: &codeLength) { payload.append(contentsOf: $0) }
            payload.append(code)
            payload.append(Data(contentDigest(data).utf8))
        }
        return contentDigest(payload)
    }

    /** Reads and hashes one complete filesystem definition generation. */
    private func definitionDigest(at directory: URL) throws -> String {
        let definitions = try definitions(at: directory)
        return Self.definitionGenerationDigest(
            Dictionary(uniqueKeysWithValues: definitions.map { ($0.planCode, $0.propertiesData) })
        )
    }

    /** Validates a complete local generation before any allocation or mutation. */
    private static func validateUnique(
        _ definitions: [RemoteSyncReadingPlanDefinition]
    ) throws {
        guard definitions.count <= maximumDefinitionCount else {
            throw RemoteSyncReadingPlanDefinitionError.tooManyDefinitions(definitions.count)
        }
        var seenCodes = Set<String>()
        var seenFilesystemIdentities = Set<String>()
        var aggregateByteCount = 0
        for definition in definitions {
            guard seenCodes.insert(definition.planCode).inserted else {
                throw RemoteSyncReadingPlanDefinitionError.duplicateDefinition(definition.planCode)
            }
            guard seenFilesystemIdentities.insert(
                filesystemIdentity(for: definition.planCode)
            ).inserted else {
                throw RemoteSyncReadingPlanDefinitionError.filesystemIdentityCollision(
                    definition.planCode
                )
            }
            let (nextAggregate, overflow) = aggregateByteCount.addingReportingOverflow(
                definition.propertiesData.count
            )
            guard !overflow,
                  nextAggregate <= maximumAggregateDefinitionByteCount else {
                throw RemoteSyncReadingPlanDefinitionError.aggregateDefinitionsTooLarge(
                    overflow ? Int.max : nextAggregate
                )
            }
            aggregateByteCount = nextAggregate
            try validate(definition)
        }
    }

    /**
     Validates one definition against Android filename and Java-properties allocation semantics.

     Numeric keys must fit signed 32-bit Android parsing. Unknown nonnumeric metadata remains valid,
     and at least one positive key is required so Android's maximum-day calculation is nonzero.
     */
    private static func validate(_ definition: RemoteSyncReadingPlanDefinition) throws {
        try validatePlanCode(definition.planCode)
        guard !ReadingPlanService.isBundledPlanCode(definition.planCode) else {
            throw RemoteSyncReadingPlanDefinitionError.bundledPlanCodeCollision(
                definition.planCode
            )
        }
        guard definition.propertiesData.count <= maximumDefinitionByteCount else {
            throw RemoteSyncReadingPlanDefinitionError.definitionTooLarge(definition.planCode)
        }
        guard !definition.propertiesData.isEmpty,
              let text = String(data: definition.propertiesData, encoding: .isoLatin1),
              hasValidUnicodeEscapes(text) else {
            throw RemoteSyncReadingPlanDefinitionError.malformedProperties(definition.planCode)
        }

        for numericKey in ReadingPlanService.numericPropertyKeys(in: text) {
            guard Int32(numericKey) != nil else {
                throw RemoteSyncReadingPlanDefinitionError.dayNumberOutOfRange(
                    definition.planCode
                )
            }
        }
        let readings = ReadingPlanService.parseProperties(text)
        guard (readings.keys.max() ?? 0) > 0 else {
            throw RemoteSyncReadingPlanDefinitionError.malformedProperties(definition.planCode)
        }
    }

    /** Verifies that one stable code is a bounded non-traversing filename stem. */
    private static func validatePlanCode(_ planCode: String) throws {
        guard !planCode.isEmpty,
              planCode.utf8.count <= maximumPlanCodeByteCount,
              planCode != ".",
              planCode != "..",
              !planCode.contains("/"),
              !planCode.contains("\\"),
              !planCode.contains("\0") else {
            throw RemoteSyncReadingPlanDefinitionError.invalidPlanCode(planCode)
        }
    }

    /** Checks Java Unicode escape structure without normalizing source bytes. */
    private static func hasValidUnicodeEscapes(_ text: String) -> Bool {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\\" else {
                index = text.index(after: index)
                continue
            }
            let escapedIndex = text.index(after: index)
            guard escapedIndex < text.endIndex else { return true }
            guard text[escapedIndex] == "u" else {
                index = text.index(after: escapedIndex)
                continue
            }
            var digitIndex = text.index(after: escapedIndex)
            for _ in 0..<4 {
                guard digitIndex < text.endIndex, text[digitIndex].isHexDigit else { return false }
                digitIndex = text.index(after: digitIndex)
            }
            index = digitIndex
        }
        return true
    }

    /** Reads one regular file through a single no-follow descriptor with a hard byte ceiling. */
    private static func readBoundedRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(url.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumByteCount) else {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(url.lastPathComponent)
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumByteCount + 1))
        while true {
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount >= 0 else {
                throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(url.lastPathComponent)
            }
            guard readCount > 0 else { break }
            guard data.count <= maximumByteCount - readCount else {
                throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(url.lastPathComponent)
            }
            data.append(buffer, count: readCount)
        }
        return data
    }

    /** Validates one decoded journal before any path derived from it can be moved or deleted. */
    private func validateJournal(_ journal: PublicationJournal) throws {
        guard let identifier = UUID(uuidString: journal.identifier),
              identifier.uuidString.lowercased() == journal.identifier,
              journal.stagingName
                == ".\(userPlanDirectory.lastPathComponent).definition-staging-\(journal.identifier)",
              journal.backupName
                == ".\(userPlanDirectory.lastPathComponent).definition-backup-\(journal.identifier)",
              Self.isSHA256(journal.previousDefinitionDigest),
              Self.isSHA256(journal.publishedDefinitionDigest),
              journal.previousDefinitionDigest != journal.publishedDefinitionDigest else {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(journal.identifier)
        }
        try validatePublicationArtifactURL(stagingURL(for: journal), journal: journal)
        try validatePublicationArtifactURL(backupURL(for: journal), journal: journal)
        try validatePublicationArtifactURL(journalURL, journal: journal)
    }

    /** Validates one generated sibling path and rejects existing symlink artifacts. */
    private func validatePublicationArtifactURL(
        _ url: URL,
        journal: PublicationJournal
    ) throws {
        let parent = userPlanDirectory.deletingLastPathComponent().standardizedFileURL
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let standardized = url.standardizedFileURL
        let canonicalArtifactParent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let allowedNames = Set([
            journal.stagingName,
            journal.backupName,
            journalURL.lastPathComponent,
        ])
        guard standardized.deletingLastPathComponent().path == parent.path,
              canonicalArtifactParent.path == canonicalParent.path,
              allowedNames.contains(standardized.lastPathComponent),
              !standardized.lastPathComponent.contains("/"),
              !standardized.lastPathComponent.contains("\\") else {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(journal.identifier)
        }
        var status = stat()
        if Darwin.lstat(standardized.path, &status) == 0,
           (status.st_mode & S_IFMT) == S_IFLNK {
            throw RemoteSyncReadingPlanDefinitionError.recoveryFailed(journal.identifier)
        }
    }

    /** Removes one validated publication artifact without following a journal-controlled path. */
    private func removeValidatedPublicationArtifact(
        _ url: URL,
        journal: PublicationJournal
    ) throws {
        try validatePublicationArtifactURL(url, journal: journal)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /** Removes only the exact configured live directory during validated rollback. */
    private func removeLiveDirectoryForRecovery(journal: PublicationJournal) throws {
        let live = userPlanDirectory.standardizedFileURL
        let parent = userPlanDirectory.deletingLastPathComponent().standardizedFileURL
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let canonicalLiveParent = live.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard live.deletingLastPathComponent().path == parent.path,
              canonicalLiveParent.path == canonicalParent.path,
              live.lastPathComponent == userPlanDirectory.lastPathComponent else {
            throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
        }
        var status = stat()
        guard Darwin.lstat(live.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw RemoteSyncReadingPlanDefinitionError.rollbackFailed(journal.identifier)
        }
        try fileManager.removeItem(at: live)
    }

    /** Returns whether one lowercase text value is an exact SHA-256 hex digest. */
    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /** Resolves the exact destination filename for one validated code. */
    private func definitionURL(for planCode: String) -> URL {
        userPlanDirectory
            .appendingPathComponent(planCode, isDirectory: false)
            .appendingPathExtension("properties")
    }

    /// Sibling journal path stable across staging-directory replacement.
    private var journalURL: URL {
        userPlanDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(userPlanDirectory.lastPathComponent).definition-publication.json"
        )
    }

    /** Resolves one journal's sibling staging path. */
    private func stagingURL(for journal: PublicationJournal) -> URL {
        userPlanDirectory.deletingLastPathComponent().appendingPathComponent(journal.stagingName)
    }

    /** Resolves one journal's sibling backup path. */
    private func backupURL(for journal: PublicationJournal) -> URL {
        userPlanDirectory.deletingLastPathComponent().appendingPathComponent(journal.backupName)
    }

    /** Flushes one newly written file before a generation rename can publish it. */
    private func synchronizeFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /** Flushes containing-directory metadata after an atomic write, rename, or removal. */
    private func synchronizeDirectory(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /** Executes one operation under the process-wide recursive definition mutation lock. */
    private func synchronized<Result>(_ operation: () throws -> Result) rethrows -> Result {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try operation()
    }

}
