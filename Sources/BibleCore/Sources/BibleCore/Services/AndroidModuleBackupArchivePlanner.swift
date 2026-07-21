import CLibSword
import Foundation
import SwordKit

/**
 Builds a typed, read-only plan from an Android module-backup ZIP archive.

 Android's backup contract is split across `BackupControl`, `CommonUtils`, and `InstallZip`:
 `AndBibleBackupManifest.json` is authoritative only when it is the literal first local ZIP entry,
 legacy archives are inferred from module-root paths, and backslashes are accepted as separators.
 The planner preserves those recognition rules while rejecting archive shapes that cannot be
 published safely on Apple filesystems. It never creates directories, extracts files, or mutates a
 module store.
 */
public struct AndroidModuleBackupArchivePlanner: Sendable {
    /// Literal manifest entry name consumed by Android only at the first local ZIP position.
    private static let manifestEntryName = "AndBibleBackupManifest.json"

    /// Current Android manifest schema understood by this planner.
    private static let supportedManifestVersion = 1

    /// Filesystem collision locale used throughout module publication code.
    private static let collisionLocale = Locale(identifier: "en_US_POSIX")

    /// Runtime categories whose Android writer packages the parent category directory.
    private static let parentDirectoryCategories: Set<String> = [
        "lexicons / dictionaries", "generic books", "maps",
    ]

    /// Drivers used to recover Android's runtime category when a conventional category is absent.
    private static let parentDirectoryDrivers: Set<String> = [
        "rawld", "rawld4", "zld", "rawgenbook",
    ]

    /// Case-insensitive JSword drivers registered by Android before installed-book discovery.
    private static let androidSupportedModuleDrivers: Set<String> = [
        "rawtext", "ztext", "ztext4",
        "rawcom", "rawcom4", "zcom", "zcom4", "hrefcom", "rawfiles",
        "rawld", "rawld4", "zld", "rawgenbook",
        "mybiblebible", "mybiblecommentary", "mybibledictionary",
        "myswordbible", "myswordcommentary", "mysworddictionary",
        "epubbook", "eswordbible",
    ]

    /// Exact UTF-8 identity of Android's reserved manifest entry.
    private static let manifestEntryBytes = Data(manifestEntryName.utf8)

    /// Resource policy enforced before any archive member is expanded.
    public let limits: AndroidModuleBackupArchiveLimits

    /**
     Creates a stateless Android module-backup planner.

     - Parameter limits: Resource ceilings applied before decompression and classification.
     - Side effects: none.
     - Failure modes: This initializer cannot fail. Invalid archive use is rejected by planning.
     */
    public init(limits: AndroidModuleBackupArchiveLimits = AndroidModuleBackupArchiveLimits()) {
        self.limits = limits
    }

    /**
     Plans an in-memory Android module-backup archive without publishing any entry.

     `existingDestinationPaths` should contain paths relative to the future modules root. Matching
     uses the same Unicode-normalized, case-insensitive key as archive collision detection, while
     returned conflict paths retain each archive entry's exact normalized spelling.

     - Parameters:
       - archiveData: Complete ZIP bytes.
       - existingDestinationPaths: Existing relative destinations used only for conflict reporting.
     - Returns: A typed plan whose entries and families preserve local ZIP order.
     The caller already owns the complete archive `Data`. Validation expands one file at a time and
     retains only manifest/configuration payloads bounded by `maximumMetadataEntryByteCount`; its
     additional peak memory is therefore bounded by one declared compressed and expanded entry.

     - Side effects: Reads and expands in-memory bytes only; performs no file or global-state writes.
     - Throws: `AndroidModuleBackupArchivePlannerError` for malformed ZIP data, unsafe destinations,
       manifest violations, unsupported content, ownership gaps, or exceeded resource limits.
     */
    public func planArchive(
        from archiveData: Data,
        existingDestinationPaths: [String] = []
    ) throws -> AndroidModuleBackupArchivePlan {
        try enforceLimit(
            .archiveBytes,
            actual: UInt64(archiveData.count),
            maximum: limits.maximumArchiveByteCount
        )

        let metadata = try AndroidModuleBackupZIPMetadataParser.parse(
            archiveData,
            limits: limits
        )
        let validatedEntries = try validatedDestinations(metadata.entries)
        try validateMetadataEntrySizes(validatedEntries)
        let inspection = try inspectArchive(entries: validatedEntries) { entry, retainPayload in
            try validatedPayload(
                for: entry,
                in: archiveData,
                retainingPayload: retainPayload
            )
        }
        let manifestDisposition = try manifestDisposition(
            entries: validatedEntries,
            firstManifestPayload: inspection.firstManifestPayload
        )
        let ownership = try validatedSwordOwnership(inspection.swordOwnership)
        let plannedEntries = try classifiedEntries(
            validatedEntries,
            ownership: ownership,
            rejectedConfigurationPaths: Set(inspection.rejectedSwordConfigurationPaths)
        )
        guard !plannedEntries.isEmpty else {
            throw AndroidModuleBackupArchivePlannerError.noModuleContent
        }
        try validateEveryConfigurationHasPayload(
            ownership,
            plannedEntries: plannedEntries
        )

        return AndroidModuleBackupArchivePlan(
            manifestDisposition: manifestDisposition,
            entries: plannedEntries,
            families: familyPlans(for: plannedEntries),
            swordModuleNames: ownership.map(\.moduleName),
            swordModuleDisplayNames: ownership.map(\.displayName),
            rejectedSwordConfigurationPaths: inspection.rejectedSwordConfigurationPaths,
            firstManifestFellBackToGenericInstall: firstManifestFellBackToGenericInstall(
                entries: validatedEntries,
                disposition: manifestDisposition
            ),
            conflictPaths: try conflictPaths(
                plannedEntries: plannedEntries,
                existingDestinationPaths: existingDestinationPaths
            ),
            aggregateCompressedByteCount: metadata.aggregateCompressedByteCount,
            aggregateExpandedByteCount: metadata.aggregateExpandedByteCount
        )
    }

    /**
     Plans a file-backed Android module archive with bounded-memory integrity validation.

     ZIP metadata is read by bounded random access. Only the first manifest and SWORD configuration
     payloads are read, inflated, and CRC-checked in memory. Their compressed and expanded sizes are
     bounded before allocation; all other payload integrity is deferred to transactional staging.

     - Parameters:
       - archiveURL: Readable local ZIP file.
       - existingDestinationPaths: Existing relative destinations used for conflict reporting.
     - Returns: A typed immutable archive plan.
     - Side effects: Opens, seeks, and reads `archiveURL`; creates no scratch files or global state.
     - Throws: File read errors or the same planner errors as `planArchive(from:)`.
     */
    public func planArchive(
        at archiveURL: URL,
        existingDestinationPaths: [String] = []
    ) throws -> AndroidModuleBackupArchivePlan {
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        if let size = (attributes[.size] as? NSNumber)?.uint64Value {
            try enforceLimit(
                .archiveBytes,
                actual: size,
                maximum: limits.maximumArchiveByteCount
            )
        }
        let metadata = try AndroidModuleBackupZIPMetadataParser.parse(
            at: archiveURL,
            limits: limits
        )
        let validatedEntries = try validatedDestinations(metadata.entries)
        try validateMetadataEntrySizes(validatedEntries)
        let inspection = try inspectArchive(entries: validatedEntries) { entry, retainPayload in
            guard retainPayload else { return nil }
            return try validatedMetadataPayload(for: entry, at: archiveURL)
        }
        let ownership = try validatedSwordOwnership(inspection.swordOwnership)
        let plannedEntries = try classifiedEntries(
            validatedEntries,
            ownership: ownership,
            rejectedConfigurationPaths: Set(inspection.rejectedSwordConfigurationPaths)
        )
        guard !plannedEntries.isEmpty else {
            throw AndroidModuleBackupArchivePlannerError.noModuleContent
        }
        try validateEveryConfigurationHasPayload(ownership, plannedEntries: plannedEntries)
        let disposition = try manifestDisposition(
            entries: validatedEntries,
            firstManifestPayload: inspection.firstManifestPayload
        )

        return AndroidModuleBackupArchivePlan(
            manifestDisposition: disposition,
            entries: plannedEntries,
            families: familyPlans(for: plannedEntries),
            swordModuleNames: ownership.map(\.moduleName),
            swordModuleDisplayNames: ownership.map(\.displayName),
            rejectedSwordConfigurationPaths: inspection.rejectedSwordConfigurationPaths,
            firstManifestFellBackToGenericInstall: firstManifestFellBackToGenericInstall(
                entries: validatedEntries,
                disposition: disposition
            ),
            conflictPaths: try conflictPaths(
                plannedEntries: plannedEntries,
                existingDestinationPaths: existingDestinationPaths
            ),
            aggregateCompressedByteCount: metadata.aggregateCompressedByteCount,
            aggregateExpandedByteCount: metadata.aggregateExpandedByteCount
        )
    }

    /**
     Validates and normalizes every local entry destination before payload expansion.

     - Parameter entries: ZIP metadata in local-header order.
     - Returns: Entries paired with exact normalized relative paths.
     - Side effects: none.
     - Throws: Unsafe-path, symlink, duplicate, or destination-collision errors.
     */
    private func validatedDestinations(
        _ entries: [AndroidModuleBackupZIPMetadataEntry]
    ) throws -> [ValidatedArchiveEntry] {
        var result: [ValidatedArchiveEntry] = []
        result.reserveCapacity(entries.count)
        var destinations: [String: ValidatedArchiveEntry] = [:]
        var destinationTreeSpellings: [String: String] = [:]

        for entry in entries {
            try enforceLimit(
                .pathBytes,
                actual: UInt64(entry.rawPathBytes.count),
                maximum: limits.maximumPathByteCount
            )
            guard !entry.isSymbolicLink else {
                throw AndroidModuleBackupArchivePlannerError.symbolicLink(entry.rawPath)
            }
            let relativePath = try normalizedRelativePath(entry.rawPath)
            let validated = ValidatedArchiveEntry(metadata: entry, relativePath: relativePath)
            let key = collisionKey(relativePath)
            if let first = destinations[key] {
                if first.relativePath.utf8.elementsEqual(relativePath.utf8) {
                    throw AndroidModuleBackupArchivePlannerError.duplicateEntry(relativePath)
                }
                throw AndroidModuleBackupArchivePlannerError.destinationCollision(
                    first: first.relativePath,
                    second: relativePath
                )
            }
            destinations[key] = validated
            let components = relativePath.split(separator: "/").map(String.init)
            for componentCount in 1...components.count {
                let spelling = components.prefix(componentCount).joined(separator: "/")
                let spellingKey = collisionKey(spelling)
                if let firstSpelling = destinationTreeSpellings[spellingKey],
                   !firstSpelling.utf8.elementsEqual(spelling.utf8) {
                    throw AndroidModuleBackupArchivePlannerError.destinationCollision(
                        first: firstSpelling,
                        second: spelling
                    )
                }
                destinationTreeSpellings[spellingKey] = spelling
            }
            result.append(validated)
        }

        for entry in result {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for componentCount in 1..<components.count {
                let parent = components.prefix(componentCount).joined(separator: "/")
                if let parentEntry = destinations[collisionKey(parent)],
                   !parentEntry.metadata.isDirectory {
                    throw AndroidModuleBackupArchivePlannerError.destinationCollision(
                        first: parentEntry.relativePath,
                        second: entry.relativePath
                    )
                }
            }
        }
        return result
    }

    /**
     Applies the tighter metadata payload bound to manifests and SWORD configuration files.

     - Parameter entries: Path-validated local entries.
     - Side effects: none.
     - Throws: A metadata resource violation before `ZipArchiveReader` expands any payload.
     */
    private func validateMetadataEntrySizes(_ entries: [ValidatedArchiveEntry]) throws {
        for entry in entries where !entry.metadata.isDirectory {
            let isManifest = androidExtractionPath(entry.metadata.rawPath) == Self.manifestEntryName
            if isManifest || isSwordConfigurationPath(entry.relativePath) {
                try enforceLimit(
                    .metadataEntryBytes,
                    actual: entry.metadata.expandedByteCount,
                    maximum: limits.maximumMetadataEntryByteCount
                )
            }
        }
    }

    /**
     Expands and CRC-checks one in-memory entry, optionally retaining its bounded metadata bytes.

     - Returns: Expanded bytes only when `retainingPayload` is true.
     - Side effects: Allocates at most one compressed and one expanded entry buffer.
     - Throws: `invalidArchive` for unsupported methods, inconsistent sizes, or CRC failure.
     */
    private func validatedPayload(
        for entry: ValidatedArchiveEntry,
        in archiveData: Data,
        retainingPayload: Bool
    ) throws -> Data? {
        let metadata = entry.metadata
        guard metadata.payloadOffset <= UInt64(Int.max),
              metadata.compressedByteCount <= UInt64(Int.max),
              metadata.payloadOffset <= UInt64(archiveData.count),
              metadata.compressedByteCount <= UInt64(archiveData.count) - metadata.payloadOffset else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP payload exceeds in-memory archive bounds"
            )
        }
        let start = Int(metadata.payloadOffset)
        let compressedCount = Int(metadata.compressedByteCount)
        let compressed = Data(archiveData[start..<(start + compressedCount)])
        return try validatedCompressedPayload(
            compressed,
            metadata: metadata,
            retainingPayload: retainingPayload
        )
    }

    /**
     Reads one bounded manifest or configuration directly from a file-backed archive.

     - Parameters:
       - entry: Path-validated metadata entry whose expanded size already passed the metadata limit.
       - archiveURL: Local archive containing the compressed member bytes.
     - Returns: Integrity-checked expanded metadata bytes.
     - Side effects: Opens, seeks, reads, and closes `archiveURL`; creates no files.
     - Throws: `invalidArchive` for oversized compressed metadata, truncated reads, decompression, or
       checksum failures; rethrows file-system failures as archive failures.
     */
    private func validatedMetadataPayload(
        for entry: ValidatedArchiveEntry,
        at archiveURL: URL
    ) throws -> Data {
        let metadata = entry.metadata
        let allowance = max(UInt64(64 * 1_024), limits.maximumMetadataEntryByteCount / 8)
        let (candidateLimit, overflow) = limits.maximumMetadataEntryByteCount
            .addingReportingOverflow(allowance)
        let compressedLimit = overflow ? UInt64.max : candidateLimit
        try enforceLimit(
            .metadataEntryBytes,
            actual: metadata.compressedByteCount,
            maximum: compressedLimit
        )
        guard metadata.compressedByteCount <= UInt64(Int.max) else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP metadata entry exceeds platform limits"
            )
        }

        do {
            let handle = try FileHandle(forReadingFrom: archiveURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: metadata.payloadOffset)
            let expectedCount = Int(metadata.compressedByteCount)
            let compressed = try handle.read(upToCount: expectedCount) ?? Data()
            guard compressed.count == expectedCount else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "ZIP metadata payload is truncated"
                )
            }
            return try validatedCompressedPayload(
                compressed,
                metadata: metadata,
                retainingPayload: true
            ) ?? Data()
        } catch let error as AndroidModuleBackupArchivePlannerError {
            throw error
        } catch {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "Unable to read ZIP metadata payload: \(error.localizedDescription)"
            )
        }
    }

    /** Expands and verifies compressed bytes already bounded by the caller. */
    private func validatedCompressedPayload(
        _ compressed: Data,
        metadata: AndroidModuleBackupZIPMetadataEntry,
        retainingPayload: Bool
    ) throws -> Data? {
        let expanded: Data
        switch metadata.compressionMethod {
        case 0:
            expanded = compressed
        case 8:
            expanded = try inflate(
                compressed,
                expectedByteCount: metadata.expandedByteCount
            )
        default:
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "Unsupported ZIP compression method \(metadata.compressionMethod)"
            )
        }
        guard UInt64(expanded.count) == metadata.expandedByteCount else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP expanded size differs from central metadata"
            )
        }
        guard ArchiveCRC32.checksum(of: expanded) == metadata.crc32 else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP entry checksum mismatch: \(metadata.rawPath)"
            )
        }
        return retainingPayload ? expanded : nil
    }

    /**
     Inflates one raw-deflate ZIP payload through the shared C adapter.

     - Returns: Expanded bytes whose final length is validated by the caller.
     - Side effects: Allocates and frees one C output buffer.
     - Throws: `invalidArchive` for platform-size overflow or decompression failure.
     */
    private func inflate(_ compressed: Data, expectedByteCount: UInt64) throws -> Data {
        guard expectedByteCount <= UInt64(Int.max) else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP entry exceeds platform limits"
            )
        }
        return try compressed.withUnsafeBytes { bytes -> Data in
            guard let baseAddress = bytes.baseAddress else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "ZIP entry decompression failed"
                )
            }
            var outputLength: UInt = 0
            guard let output = inflate_raw_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(compressed.count),
                UInt(expectedByteCount),
                &outputLength
            ) else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "ZIP entry decompression failed"
                )
            }
            defer { gunzip_free(output) }
            guard outputLength <= UInt(Int.max) else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "ZIP entry exceeds platform limits"
                )
            }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    /**
     Reads and validates only metadata payloads needed for archive recognition.

     - Parameters:
       - entries: Path-validated entries in local order.
       - validatePayload: Backend-specific integrity validator. It returns bytes only when asked to
         retain a bounded manifest or configuration payload.
     - Returns: First-manifest bytes, valid SWORD ownership descriptors, and independently rejected
       configuration paths.
     - Side effects: Delegates bounded manifest/configuration reads to `validatePayload`.
     - Throws: Integrity, metadata-decoding, or SWORD configuration errors.
     */
    private func inspectArchive(
        entries: [ValidatedArchiveEntry],
        validatePayload: (ValidatedArchiveEntry, Bool) throws -> Data?
    ) throws -> ArchiveInspection {
        var firstManifestPayload: Data?
        var swordOwnership: [SwordConfigurationOwnership] = []
        var rejectedSwordConfigurationPaths: [String] = []
        for entry in entries where !entry.metadata.isDirectory {
            let isFirstManifest = entry.metadata.archivePosition == 0
                && entry.metadata.rawPathBytes == Self.manifestEntryBytes
            let isConfiguration = isSwordConfigurationPath(entry.relativePath)
            let retainPayload = isFirstManifest || isConfiguration
            let payload = retainPayload ? try validatePayload(entry, true) : nil

            if isFirstManifest {
                guard let payload else {
                    throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                        "First manifest payload was not retained"
                    )
                }
                firstManifestPayload = payload
            }
            if isConfiguration {
                guard let payload,
                      UInt64(payload.count) <= limits.maximumMetadataEntryByteCount,
                      var content = String(data: payload, encoding: .utf8) else {
                    rejectedSwordConfigurationPaths.append(entry.relativePath)
                    continue
                }
                if content.first == "\u{feff}" {
                    content.removeFirst()
                }
                do {
                    swordOwnership.append(try parseSwordOwnership(
                        configurationPath: entry.relativePath,
                        content: content
                    ))
                } catch let error as AndroidModuleBackupArchivePlannerError {
                    switch error {
                    case .malformedSwordConfiguration, .swordConfigurationNameMismatch:
                        rejectedSwordConfigurationPaths.append(entry.relativePath)
                    default:
                        throw error
                    }
                }
            }
        }
        return ArchiveInspection(
            firstManifestPayload: firstManifestPayload,
            swordOwnership: swordOwnership,
            rejectedSwordConfigurationPaths: rejectedSwordConfigurationPaths
        )
    }

    /**
     Converts shared file-backed ZIP reader failures into planner failures.

     - Parameter archiveURL: Local ZIP file.
     - Returns: Non-directory entries in central order.
     - Side effects: Opens and reads archive metadata through `ZipArchiveReader`.
     - Throws: File-system errors or a normalized planner archive error.
     */
    private func zipFileEntries(at archiveURL: URL) throws -> [ZipArchiveFileEntry] {
        do {
            return try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)
        } catch let error as ZipArchiveReaderError {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                Self.archiveErrorDescription(error)
            )
        } catch {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                error.localizedDescription
            )
        }
    }

    /**
     Binds shared file-reader entries to stricter byte-exact parser metadata.

     - Parameters:
       - fileEntries: Shared reader entries in central order.
       - entries: Stricter parser entries in local order.
     - Returns: Shared reader entries keyed by central position.
     - Side effects: none.
     - Throws: `invalidArchive` when any decoded identity, raw name bytes, size, method, checksum, or
       local/payload offset differs.
     */
    private func boundFileEntries(
        _ fileEntries: [ZipArchiveFileEntry],
        to entries: [ValidatedArchiveEntry]
    ) throws -> [Int: ZipArchiveFileEntry] {
        let metadataFiles = entries
            .filter { !$0.metadata.isDirectory }
            .sorted {
                $0.metadata.centralDirectoryPosition < $1.metadata.centralDirectoryPosition
            }
        guard metadataFiles.count == fileEntries.count else {
            throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                "ZIP file-entry metadata is inconsistent"
            )
        }
        var result: [Int: ZipArchiveFileEntry] = [:]
        result.reserveCapacity(fileEntries.count)
        for (metadataEntry, fileEntry) in zip(metadataFiles, fileEntries) {
            let metadata = metadataEntry.metadata
            guard fileEntry.name == metadata.rawPath,
                  Data(fileEntry.name.utf8) == metadata.rawPathBytes,
                  fileEntry.compressionMethod == metadata.compressionMethod,
                  fileEntry.compressedSize == metadata.compressedByteCount,
                  fileEntry.uncompressedSize == metadata.expandedByteCount,
                  fileEntry.checksum == metadata.crc32,
                  fileEntry.localHeaderOffset == metadata.localHeaderOffset,
                  fileEntry.dataOffset == metadata.payloadOffset else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "ZIP parser identities are inconsistent"
                )
            }
            result[metadata.centralDirectoryPosition] = fileEntry
        }
        return result
    }

    /**
     Reproduces Android's literal first-entry manifest rule.

     Android catches any first-manifest decode failure and proceeds through generic module install.
     The same fallback applies to unknown backup types and future schemas. A successfully decoded
     StudyPad export remains special and is rejected because this planner cannot install StudyPad.

     - Parameters:
       - entries: Validated entries in local ZIP order.
       - firstManifestPayload: Integrity-checked bytes retained only for an exact first manifest.
     - Returns: Validated first-entry manifest or a typed legacy disposition.
     - Side effects: none.
     - Throws: `unsupportedBackupType` only for a decoded `STUDYPAD_EXPORT` manifest.
     */
    private func manifestDisposition(
        entries: [ValidatedArchiveEntry],
        firstManifestPayload: Data?
    ) throws -> AndroidModuleBackupManifestDisposition {
        if let first = entries.first,
           !first.metadata.isDirectory,
           first.metadata.rawPathBytes == Self.manifestEntryBytes {
            guard let firstManifestPayload else {
                throw AndroidModuleBackupArchivePlannerError.invalidArchive(
                    "First manifest payload is missing"
                )
            }
            guard let dto = try? JSONDecoder().decode(ManifestDTO.self, from: firstManifestPayload) else {
                return .legacyManifestNotFirst
            }
            if dto.backupType == "STUDYPAD_EXPORT" {
                throw AndroidModuleBackupArchivePlannerError.unsupportedBackupType(dto.backupType)
            }
            guard dto.backupType == AndroidModuleBackupArchiveType.moduleBackup.rawValue,
                  dto.manifestVersion == Self.supportedManifestVersion else {
                return .legacyManifestNotFirst
            }
            return .validatedFirstEntry(AndroidModuleBackupArchiveManifest(
                backupType: .moduleBackup,
                contains: dto.contains,
                manifestVersion: dto.manifestVersion,
                andBibleVersion: dto.andBibleVersion
            ))
        }

        let containsLaterManifest = entries.contains { entry in
            !entry.metadata.isDirectory
                && androidExtractionPath(entry.metadata.rawPath) == Self.manifestEntryName
        }
        return containsLaterManifest ? .legacyManifestNotFirst : .legacyWithoutManifest
    }

    /**
     Reports whether Android abandoned typed backup routing after reading the exact first manifest.

     - Parameters:
       - entries: Validated archive entries in local order.
       - disposition: Android-compatible manifest parse result.
     - Returns: `true` only for an exact first manifest that did not validate as `MODULE_BACKUP`.
     - Side effects: None.
     - Failure modes: None; malformed bytes are already represented by `disposition`.
     */
    private func firstManifestFellBackToGenericInstall(
        entries: [ValidatedArchiveEntry],
        disposition: AndroidModuleBackupManifestDisposition
    ) -> Bool {
        guard let first = entries.first,
              !first.metadata.isDirectory,
              first.metadata.rawPathBytes == Self.manifestEntryBytes else {
            return false
        }
        if case .validatedFirstEntry = disposition {
            return false
        }
        return true
    }

    /**
     Validates module-name uniqueness and ownership overlap in time bounded by path depth.

     `firstDescendantOwnerByAncestor` avoids rescanning prior configurations when detecting a new
     root that contains an existing root. Together with ancestor lookups this replaces the prior
     quadratic pairwise comparison.

     - Parameter ownership: Parsed configuration descriptors in archive order.
     - Returns: The unchanged descriptors after uniqueness/overlap validation.
     - Side effects: none.
     - Throws: Duplicate initials or overlapping ownership errors.
     */
    private func validatedSwordOwnership(
        _ ownership: [SwordConfigurationOwnership]
    ) throws -> [SwordConfigurationOwnership] {
        var seenModuleNames = Set<String>()
        var ownerIndexByRoot: [String: Int] = [:]
        var firstDescendantOwnerByAncestor: [String: Int] = [:]
        for (index, configuration) in ownership.enumerated() {
            guard seenModuleNames.insert(collisionKey(configuration.moduleName)).inserted else {
                throw AndroidModuleBackupArchivePlannerError.duplicateSwordModuleInitials(
                    configuration.moduleName
                )
            }
            let rootKey = configuration.dataDirectoryKey
            let ancestorKeys = properAncestorKeys(for: configuration.dataDirectory)
            let candidates = [ownerIndexByRoot[rootKey], firstDescendantOwnerByAncestor[rootKey]]
                + ancestorKeys.map { ownerIndexByRoot[$0] }
            if let overlappingIndex = candidates.compactMap({ $0 }).min() {
                throw AndroidModuleBackupArchivePlannerError.overlappingSwordOwnership(
                    first: ownership[overlappingIndex].configurationPath,
                    second: configuration.configurationPath
                )
            }
            ownerIndexByRoot[rootKey] = index
            for ancestorKey in ancestorKeys where firstDescendantOwnerByAncestor[ancestorKey] == nil {
                firstDescendantOwnerByAncestor[ancestorKey] = index
            }
        }
        return ownership
    }

    /**
     Converts one SWORD config into the directory tree selected by Android's backup writer.

     Android writes the complete `DataPath` tree for ordinary categories. Dictionaries, general
     books, and maps instead write its parent runtime-category directory, including non-prefix
     siblings. A config-owned FontPack (`Category=And Bible`, `DataPath=./ttf/`) remains rooted at
     `ttf` and therefore takes precedence over generic TTF registration.

     - Parameters:
       - configurationPath: Exact normalized `mods.d` destination.
       - content: UTF-8 SWORD configuration text.
     - Returns: Normalized ownership descriptor.
     - Side effects: none.
     - Throws: `malformedSwordConfiguration` for missing/unsupported metadata, or
       `unsafeSwordConfigurationDataPath` for absolute, encoded, NUL, traversing, or reserved roots.
     */
    private func parseSwordOwnership(
        configurationPath: String,
        content: String
    ) throws -> SwordConfigurationOwnership {
        var sectionName: String?
        var dataPath: String?
        var driver: String?
        var category: String?
        var versification: String?
        var description: String?
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if sectionName == nil, line.hasPrefix("["), line.hasSuffix("]") {
                let candidate = line.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    sectionName = candidate
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare("DataPath") == .orderedSame, dataPath == nil {
                dataPath = value
            } else if key.caseInsensitiveCompare("ModDrv") == .orderedSame, driver == nil {
                driver = value
            } else if key.caseInsensitiveCompare("Category") == .orderedSame, category == nil {
                category = value
            } else if key.caseInsensitiveCompare("Versification") == .orderedSame,
                      versification == nil {
                versification = value
            } else if key.caseInsensitiveCompare("Description") == .orderedSame,
                      description == nil {
                description = value
            }
        }

        guard let sectionName, !sectionName.isEmpty,
              !sectionName.contains("/"),
              !sectionName.contains("\\"),
              !sectionName.contains("%") else {
            throw AndroidModuleBackupArchivePlannerError.malformedSwordConfiguration(
                configurationPath
            )
        }
        guard let dataPath else {
            throw AndroidModuleBackupArchivePlannerError.malformedSwordConfiguration(
                configurationPath
            )
        }
        guard !dataPath.isEmpty else {
            throw AndroidModuleBackupArchivePlannerError.unsafeSwordConfigurationDataPath(
                configurationPath
            )
        }
        let configurationName = ((configurationPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        guard configurationName.caseInsensitiveCompare(sectionName) == .orderedSame else {
            throw AndroidModuleBackupArchivePlannerError.swordConfigurationNameMismatch(
                path: configurationPath,
                moduleName: sectionName
            )
        }

        var lexicalDataPath = dataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if lexicalDataPath.hasPrefix("./") {
            lexicalDataPath.removeFirst(2)
        }
        guard !lexicalDataPath.isEmpty,
              !lexicalDataPath.hasPrefix("/"),
              !lexicalDataPath.contains("\\"),
              !lexicalDataPath.contains("%"),
              !lexicalDataPath.contains("\0") else {
            throw AndroidModuleBackupArchivePlannerError.unsafeSwordConfigurationDataPath(
                configurationPath
            )
        }
        let trailingSlash = lexicalDataPath.hasSuffix("/")
        var components = lexicalDataPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        if trailingSlash, components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AndroidModuleBackupArchivePlannerError.unsafeSwordConfigurationDataPath(
                configurationPath
            )
        }

        let normalizedDriver = (driver ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Self.collisionLocale)
        guard Self.androidSupportedModuleDrivers.contains(normalizedDriver),
              JSwordVersificationRegistry.supports(versification ?? "") else {
            throw AndroidModuleBackupArchivePlannerError.malformedSwordConfiguration(
                configurationPath
            )
        }
        let normalizedCategory = category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Self.collisionLocale)
        let categorySelectsParent = normalizedCategory.map {
            Self.parentDirectoryCategories.contains($0)
        } ?? false
        let driverInfersParent = (normalizedCategory == nil || normalizedCategory == "other")
            && Self.parentDirectoryDrivers.contains(normalizedDriver)
        let dataDirectory: String
        if categorySelectsParent || driverInfersParent {
            guard components.count > 1 else {
                throw AndroidModuleBackupArchivePlannerError.unsafeSwordConfigurationDataPath(
                    configurationPath
                )
            }
            dataDirectory = components.dropLast().joined(separator: "/")
        } else {
            dataDirectory = components.joined(separator: "/")
        }

        let firstRoot = dataDirectory.split(separator: "/").first.map(String.init)
        guard !dataDirectory.isEmpty,
              firstRoot != "mods.d",
              dataDirectory != Self.manifestEntryName else {
            throw AndroidModuleBackupArchivePlannerError.unsafeSwordConfigurationDataPath(
                configurationPath
            )
        }
        return SwordConfigurationOwnership(
            configurationPath: configurationPath,
            moduleName: sectionName,
            displayName: description?.isEmpty == false ? description! : sectionName,
            dataDirectory: dataDirectory,
            dataDirectoryKey: collisionKey(dataDirectory)
        )
    }

    /**
     Classifies every safe extracted file while limiting registration families to Android discovery.

     Config ownership precedes root-based discovery so config-owned FontPack TTF files stay with
     their SWORD config. Android's generic installer also preserves safe unowned members beneath
     `mods.d`, `modules`, and its four raw module roots; those remain generic payload without
     contributing an installed-book identity.

     - Parameters:
       - entries: Validated local entries.
       - ownership: Parsed SWORD configuration ownership roots.
       - rejectedConfigurationPaths: Metadata-invalid activation files omitted from publication.
     - Returns: Installable file entries in local ZIP order.
     - Side effects: none.
     - Throws: `ambiguousSwordPayload` for overlapping owners or `unsupportedEntry` for unowned
       payloads outside Android's registered families.
     */
    private func classifiedEntries(
        _ entries: [ValidatedArchiveEntry],
        ownership: [SwordConfigurationOwnership],
        rejectedConfigurationPaths: Set<String>
    ) throws -> [AndroidModuleBackupPlannedEntry] {
        let ownerIndexByRoot = Dictionary(uniqueKeysWithValues: ownership.enumerated().map {
            ($0.element.dataDirectoryKey, $0.offset)
        })
        var result: [AndroidModuleBackupPlannedEntry] = []
        for entry in entries {
            if androidExtractionPath(entry.metadata.rawPath) == Self.manifestEntryName {
                continue
            }
            if entry.metadata.isDirectory {
                continue
            }
            if rejectedConfigurationPaths.contains(entry.relativePath) {
                continue
            }

            let ownerIndexes = pathAndAncestorKeys(for: entry.relativePath)
                .compactMap { ownerIndexByRoot[$0] }
            guard ownerIndexes.count <= 1 else {
                throw AndroidModuleBackupArchivePlannerError.ambiguousSwordPayload(entry.relativePath)
            }
            let owners = ownerIndexes.map { ownership[$0] }

            let family: AndroidModuleBackupContentFamily
            if isSwordConfigurationPath(entry.relativePath) {
                family = .swordConfiguration
            } else if !owners.isEmpty {
                family = .swordPayload
            } else if let knownFamily = knownFamily(for: entry.relativePath) {
                family = knownFamily
            } else if isAndroidGenericExtractionPath(entry.relativePath) {
                family = .swordPayload
            } else {
                throw AndroidModuleBackupArchivePlannerError.unsupportedEntry(entry.relativePath)
            }

            result.append(AndroidModuleBackupPlannedEntry(
                archivePosition: entry.metadata.archivePosition,
                sourcePath: entry.metadata.rawPath,
                relativePath: entry.relativePath,
                family: family,
                compressedByteCount: entry.metadata.compressedByteCount,
                expandedByteCount: entry.metadata.expandedByteCount,
                crc32: entry.metadata.crc32,
                owningConfigurationPaths: owners.map(\.configurationPath)
            ))
        }
        return result
    }

    /**
     Reports whether Android extracts one safe member without assigning a specialized registrar.

     - Parameter path: Validated normalized archive destination.
     - Returns: `true` for descendants of Android's generic config/data roots or externally
       recognized raw module roots; `false` for unrelated archive content.
     - Side effects: None.
     - Failure modes: None; path safety and destination collisions were validated earlier.
     */
    private func isAndroidGenericExtractionPath(_ path: String) -> Bool {
        guard let root = path.split(separator: "/", omittingEmptySubsequences: false).first else {
            return false
        }
        return ["mods.d", "modules", "epub", "mysword", "mybible", "esword"].contains(root)
    }

    /**
     Requires each SWORD configuration to own at least one planned non-configuration payload.

     - Parameters:
       - ownership: Parsed SWORD ownership descriptors.
       - plannedEntries: Classified installable entries.
     - Side effects: none.
     - Throws: `missingSwordPayload` for an incomplete configuration.
     */
    private func validateEveryConfigurationHasPayload(
        _ ownership: [SwordConfigurationOwnership],
        plannedEntries: [AndroidModuleBackupPlannedEntry]
    ) throws {
        let configurationsWithPayload = Set(plannedEntries
            .filter { $0.family != .swordConfiguration }
            .flatMap(\.owningConfigurationPaths))
        for configuration in ownership {
            guard configurationsWithPayload.contains(configuration.configurationPath) else {
                throw AndroidModuleBackupArchivePlannerError.missingSwordPayload(
                    configuration.configurationPath
                )
            }
        }
    }

    /**
     Groups classified entries by family while preserving first-family and per-family archive order.

     - Parameter entries: Classified entries in local ZIP order.
     - Returns: Stable typed family groups.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private func familyPlans(
        for entries: [AndroidModuleBackupPlannedEntry]
    ) -> [AndroidModuleBackupFamilyPlan] {
        var familyOrder: [AndroidModuleBackupContentFamily] = []
        var entriesByFamily: [AndroidModuleBackupContentFamily: [AndroidModuleBackupPlannedEntry]] = [:]
        for entry in entries {
            if entriesByFamily[entry.family] == nil {
                familyOrder.append(entry.family)
            }
            entriesByFamily[entry.family, default: []].append(entry)
        }
        return familyOrder.map { family in
            AndroidModuleBackupFamilyPlan(
                family: family,
                entries: entriesByFamily[family] ?? []
            )
        }
    }

    /**
     Finds planned paths colliding with caller-supplied existing destination spellings.

     - Parameters:
       - plannedEntries: Unique validated archive destinations.
       - existingDestinationPaths: Relative existing paths supplied by a future transaction owner.
     - Returns: Conflicting archive paths in local ZIP order.
     - Side effects: none.
     - Throws: `unsafeEntryPath` when an existing relative-path input is not safely normalizable.
     */
    private func conflictPaths(
        plannedEntries: [AndroidModuleBackupPlannedEntry],
        existingDestinationPaths: [String]
    ) throws -> [String] {
        var existingKeys = Set<String>()
        var existingAncestorKeys = Set<String>()
        for path in existingDestinationPaths {
            let normalized = try normalizedRelativePath(path)
            existingKeys.insert(collisionKey(normalized))
            existingAncestorKeys.formUnion(properAncestorKeys(for: normalized))
        }
        return plannedEntries.compactMap { entry in
            let key = collisionKey(entry.relativePath)
            let existingPathBlocksDescendant = properAncestorKeys(for: entry.relativePath)
                .contains { existingKeys.contains($0) }
            let plannedPathBlocksExistingDescendant = existingAncestorKeys.contains(key)
            return existingKeys.contains(key)
                || existingPathBlocksDescendant
                || plannedPathBlocksExistingDescendant
                ? entry.relativePath
                : nil
        }
    }

    /**
     Produces collision keys for a path and each of its ancestors.

     - Parameter path: Normalized non-empty relative path.
     - Returns: Keys from the first component through the complete path.
     - Side effects: none.
     - Failure modes: This deterministic transformation cannot fail.
     */
    private func pathAndAncestorKeys(for path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        return (1...components.count).map { count in
            collisionKey(components.prefix(count).joined(separator: "/"))
        }
    }

    /**
     Produces collision keys for every proper ancestor of a path.

     - Parameter path: Normalized non-empty relative path.
     - Returns: Root-to-parent keys, excluding the complete path.
     - Side effects: none.
     - Failure modes: This deterministic transformation cannot fail.
     */
    private func properAncestorKeys(for path: String) -> [String] {
        Array(pathAndAncestorKeys(for: path).dropLast())
    }

    /**
     Applies Android registrar extension and depth requirements to one extracted file.

     - Parameter path: Exact normalized relative file path.
     - Returns: A family for recognized roots, or `nil` for config-owned/unsupported roots.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private func knownFamily(for path: String) -> AndroidModuleBackupContentFamily? {
        let components = path.split(separator: "/").map(String.init)
        guard let root = components.first, components.count >= 2 else {
            return nil
        }
        let pathExtension = (components.last! as NSString).pathExtension
            .lowercased(with: Self.collisionLocale)
        switch root {
        case "mybible" where pathExtension == "sqlite3": return .myBible
        case "mysword" where pathExtension == "mybible": return .mySword
        case "esword" where components.count == 2
            && ["bblx", "bbli"].contains(pathExtension): return .eSword
        case "epub" where components.count >= 3: return .epub
        case "ttf" where pathExtension == "ttf": return .ttf
        case "background" where ["jpg", "jpeg", "png", "webp"].contains(pathExtension):
            return .background
        case "prompts" where components.count == 2 && pathExtension == "csv": return .prompts
        default: return nil
        }
    }

    /**
     Detects a SWORD config path using Android's case-sensitive `mods.d` and `.conf` rules.

     - Parameter path: Exact normalized relative path.
     - Returns: `true` only for a descendant `.conf` file under `mods.d`.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private func isSwordConfigurationPath(_ path: String) -> Bool {
        path.hasPrefix("mods.d/") && path.hasSuffix(".conf")
    }

    /**
     Normalizes Android-accepted path syntax without changing case or Unicode spelling.

     Backslashes become separators and repeated separators plus `.` components are benign. Every
     `..` component is rejected even when lexical normalization would remain beneath the root. This
     deliberate iOS security extension preserves Android routing without inheriting traversal bugs.
     Absolute paths, Windows drive roots, and NUL bytes are also rejected.

     - Parameter rawPath: ZIP entry name or caller-supplied relative path.
     - Returns: Exact normalized non-empty relative path.
     - Side effects: none.
     - Throws: `unsafeEntryPath` when the path cannot remain inside the destination root.
     */
    private func normalizedRelativePath(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty, !rawPath.contains("\0") else {
            throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
        }
        let separatorsNormalized = androidExtractionPath(rawPath)
        guard !separatorsNormalized.hasPrefix("/") else {
            throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
        }
        if separatorsNormalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .last(where: { !$0.isEmpty }) == "." {
            throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
        }

        let firstComponent = separatorsNormalized.split(separator: "/", omittingEmptySubsequences: true).first
        if let firstComponent,
           firstComponent.count == 2,
           firstComponent.last == ":",
           firstComponent.first?.isASCII == true,
           firstComponent.first?.isLetter == true {
            throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
        }

        var components: [Substring] = []
        for component in separatorsNormalized.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
            } else {
                components.append(component)
            }
        }
        guard !components.isEmpty else {
            throw AndroidModuleBackupArchivePlannerError.unsafeEntryPath(rawPath)
        }
        return components.joined(separator: "/")
    }

    /**
     Applies Android extraction's separator conversion without resolving path components.

     - Parameter path: Raw ZIP or configuration path.
     - Returns: The same scalar content with backslashes replaced by forward slashes.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private func androidExtractionPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    /**
     Creates the deterministic case/Unicode filesystem key used for collision checks.

     - Parameter path: Exact normalized relative path.
     - Returns: Canonically composed, case-folded comparison key.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Self.collisionLocale)
    }

    /**
     Throws a typed resource error when an actual value exceeds policy.

     - Parameters:
       - resource: Resource category being checked.
       - actual: Declared or measured use.
       - maximum: Inclusive policy ceiling.
     - Side effects: none.
     - Throws: `resourceLimitExceeded` when `actual` is greater than `maximum`.
     */
    private func enforceLimit(
        _ resource: AndroidModuleBackupArchiveResource,
        actual: UInt64,
        maximum: UInt64
    ) throws {
        guard actual <= maximum else {
            throw AndroidModuleBackupArchivePlannerError.resourceLimitExceeded(
                resource: resource,
                limit: maximum,
                actual: actual
            )
        }
    }

    /**
     Converts shared ZIP reader failures into stable planner diagnostics.

     - Parameter error: Error emitted by `ZipArchiveReader`.
     - Returns: Concise archive failure text.
     - Side effects: none.
     - Failure modes: This operation cannot fail.
     */
    private static func archiveErrorDescription(_ error: ZipArchiveReaderError) -> String {
        switch error {
        case .missingCentralDirectory:
            return "Missing ZIP central directory"
        case .invalidArchive(let message):
            return message
        case .unsupportedCompressionMethod(let method):
            return "Unsupported ZIP compression method \(method)"
        case .decompressionFailed:
            return "ZIP entry decompression failed"
        }
    }
}

/**
 Android manifest decoder with Kotlin-compatible absent-versus-null defaults.

 Android supplies runtime defaults when `manifestVersion` or `andBibleVersion` is absent, but a
 literal JSON `null` for either non-null field fails decoding and triggers generic installation.
 The iOS planner uses `0` as a deterministic unknown Android application-version sentinel because
 it cannot reproduce the producing Android process's runtime application version.
 */
private struct ManifestDTO: Decodable {
    /// Raw Android backup enum spelling.
    let backupType: String

    /// Optional Android database-content set.
    let contains: Set<AndroidModuleBackupArchiveContainedData>?

    /// Manifest schema version, defaulting to Android's version `1` only when omitted.
    let manifestVersion: Int

    /// Producing Android application version, or deterministic unknown sentinel `0` when omitted.
    let andBibleVersion: Int

    /// JSON keys written by Android's serializable manifest.
    private enum CodingKeys: String, CodingKey {
        case backupType
        case contains
        case manifestVersion
        case andBibleVersion
    }

    /**
     Decodes required and defaulted Android manifest fields.

     - Parameter decoder: JSON decoder positioned at the manifest object.
     - Side effects: Reads decoder state only.
     - Throws: Standard decoding errors for missing/type-invalid fields, including explicit `null`
       for either defaulted non-null integer.
     */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backupType = try container.decode(String.self, forKey: .backupType)
        contains = try container.decodeIfPresent(
            Set<AndroidModuleBackupArchiveContainedData>.self,
            forKey: .contains
        )
        manifestVersion = container.contains(.manifestVersion)
            ? try container.decode(Int.self, forKey: .manifestVersion)
            : 1
        andBibleVersion = container.contains(.andBibleVersion)
            ? try container.decode(Int.self, forKey: .andBibleVersion)
            : 0
    }
}

/**
 Bounded metadata retained after every archive payload passes integrity validation.
 */
private struct ArchiveInspection {
    /// Exact first-manifest bytes when the first local entry has the reserved byte identity.
    let firstManifestPayload: Data?

    /// Parsed SWORD configuration descriptors in local entry order.
    let swordOwnership: [SwordConfigurationOwnership]

    /// Metadata-invalid configuration paths retained for valid-sibling restore diagnostics.
    let rejectedSwordConfigurationPaths: [String]
}

/**
 One ZIP metadata entry paired with its validated destination path.
 */
private struct ValidatedArchiveEntry {
    /// Parsed ZIP metadata.
    let metadata: AndroidModuleBackupZIPMetadataEntry

    /// Exact normalized modules-directory-relative path.
    let relativePath: String
}

/**
 Normalized payload ownership derived from one SWORD configuration.
 */
private struct SwordConfigurationOwnership {
    /// Exact normalized config destination.
    let configurationPath: String

    /// SWORD section initials retained for diagnostics and future integration.
    let moduleName: String

    /// Full SWORD name used by JSword's cross-family `Books.getBook` lookup.
    let displayName: String

    /// Directory containing this configuration's payload files.
    let dataDirectory: String

    /// Canonical case-folded key used by bounded ownership indexes.
    let dataDirectoryKey: String
}
