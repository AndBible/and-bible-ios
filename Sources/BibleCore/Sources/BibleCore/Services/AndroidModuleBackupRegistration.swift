// AndroidModuleBackupRegistration.swift -- Durable Android-family restore registration

import Foundation
import SwordKit

/** One raw Android family member that requires durable iOS discovery metadata after restore. */
internal struct AndroidModuleBackupRegistrationCandidate: Sendable, Equatable {
    /// Android family whose startup registrar owns the payload.
    internal let family: AndroidModuleBackupContentFamily

    /// Exact file or EPUB-root path relative to the module store.
    internal let relativePath: String

    /// Android runtime initials allocated under first-winner semantics.
    internal let initials: String

    /// Filename-derived presentation name used until a database reader supplies richer metadata.
    internal let displayName: String

    /// Deterministic generated configuration destination beneath `mods.d`.
    internal let configurationRelativePath: String
}

/** Registration identities and activation paths available before archive bytes are extracted. */
internal struct AndroidModuleBackupRegistrationPreview: Sendable, Equatable {
    /// Readable live rows used to repeat final identity arbitration after staged metadata parsing.
    internal let installedContent: [AndroidModuleBackupInstalledContent]

    /// Archive-owned rows in exact Android registration order.
    internal let archiveContent: [AndroidModuleBackupInstalledContent]

    /// Accepted custom-family candidates in registration order.
    internal let candidates: [AndroidModuleBackupRegistrationCandidate]

    /// SWORD configuration paths admitted after global initials/full-name collision checks.
    internal let acceptedSwordConfigurationPaths: [String]

    /// Generated activation paths added to conflict inspection and publication.
    internal var generatedConfigurationPaths: [String] {
        candidates.map(\.configurationRelativePath)
    }

    /// Exact EPUB roots whose native generations must join the publication transaction.
    internal var epubRelativeRoots: [String] {
        candidates.filter { $0.family == .epub }.map(\.relativePath)
    }
}

/** Staged registration metadata plus the exact archive rows validated from real payloads. */
internal struct AndroidModuleBackupPreparedRegistration: Sendable, Equatable {
    /// Archive-owned rows after SQLite metadata validation.
    internal let archiveContent: [AndroidModuleBackupInstalledContent]

    /// Custom-family candidates whose configs were staged.
    internal let candidates: [AndroidModuleBackupRegistrationCandidate]

    /// Malformed supported-family candidates excluded before one atomic publication.
    internal let diagnostics: [AndroidModuleBackupRestoreDiagnostic]

    /// Generated config paths published after every payload.
    internal var generatedConfigurationPaths: [String] {
        candidates.map(\.configurationRelativePath)
    }

    /// Exact EPUB roots installed into the native immutable-generation library.
    internal var epubRelativeRoots: [String] {
        candidates.filter { $0.family == .epub }.map(\.relativePath)
    }
}

/**
 Allocates and stages durable registrations for Android raw-file module families.

 Android constructs these books in memory after SWORD startup. iOS persists equivalent generated
 configs because its runtime registries are split across SwordKit and BibleCore. Generated configs
 are marked and excluded from outgoing backups, leaving each raw family with Android's exact one-file
 ownership. Identity allocation uses the shared all-family first-winner registry.
 */
internal struct AndroidModuleBackupRegistrationBuilder {
    /// Maximum generated registration metadata read from an existing install.
    private static let maximumRegistrationConfigurationByteCount = 64 * 1_024

    /// Families in Android's post-SWORD startup registration order.
    private static let customFamilyOrder: [AndroidModuleBackupContentFamily] = [
        .myBible,
        .mySword,
        .eSword,
        .epub,
        .ttf,
        .background,
        .prompts,
    ]

    /// Supported Android manual background extensions.
    private static let backgroundExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Module-store root that receives archive and generated files.
    private let moduleDirectory: URL

    /// Filesystem dependency used for bounded existing-config reads and exact-path checks.
    private let fileManager: FileManager

    /** Creates a registration builder without reading or mutating installed state. */
    internal init(moduleDirectory: URL, fileManager: FileManager) {
        self.moduleDirectory = moduleDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    /**
     Allocates archive identities and generated destinations before extraction.

     - Parameters:
       - plan: Validated archive plan in local ZIP order.
       - installedContent: Canonical all-family installed catalog from the export inventory builder.
     - Returns: Archive rows and custom registrations in Android family order.
     - Side effects: Bounded-reads deterministic existing generated configs and checks exact live
       backing paths to keep repeated restores idempotent.
     - Throws: `AndroidModuleBackupError.invalidModuleLayout` for generated/archive destination
       collisions or unsafe persistent config identities.
     */
    internal func preview(
        plan: AndroidModuleBackupArchivePlan,
        installedContent: [AndroidModuleBackupInstalledContent]
    ) throws -> AndroidModuleBackupRegistrationPreview {
        try Task.checkCancellation()
        var registry = AndroidModuleBackupIdentityRegistry()
        var archiveContent: [AndroidModuleBackupInstalledContent] = []
        var candidates: [AndroidModuleBackupRegistrationCandidate] = []
        var acceptedSwordConfigurationPaths: [String] = []

        for content in installedContent where content.family == .swordConfiguration {
            _ = registry.claim(content)
        }
        let swordConfigurationEntries = plan.entries.filter {
            $0.family == .swordConfiguration
        }
        guard swordConfigurationEntries.count == plan.swordModuleNames.count,
              swordConfigurationEntries.count == plan.swordModuleDisplayNames.count else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "SWORD configuration identities do not match archive entries."
            )
        }
        for index in swordConfigurationEntries.indices {
            let configurationEntry = swordConfigurationEntries[index]
            let initials = plan.swordModuleNames[index]
            let displayName = plan.swordModuleDisplayNames[index]
            try validateConfigToken(initials, field: "SWORD initials")
            let content = AndroidModuleBackupInstalledContent(
                initials: initials,
                displayName: displayName,
                language: "",
                family: .swordConfiguration
            )
            if let winner = registry.content(matching: initials) {
                let replacesInstalledSword = winner.family == .swordConfiguration
                    && SQLiteDocumentIdentity(winner.initials) == SQLiteDocumentIdentity(initials)
                guard replacesInstalledSword,
                      registry.replace(content, replacing: winner) else { continue }
            } else {
                guard registry.claim(content) else { continue }
            }
            appendArchiveContent(content, to: &archiveContent)
            acceptedSwordConfigurationPaths.append(configurationEntry.relativePath)
        }

        let rawCandidates = try discoveredCandidates(plan: plan)
        let plannedPathKeys = Set(plan.entries.map { collisionKey($0.relativePath) })
        var generatedPathKeys = Set<String>()

        for family in Self.customFamilyOrder {
            try Task.checkCancellation()
            for content in installedContent where content.family == family {
                _ = registry.claim(content)
            }

            for rawCandidate in rawCandidates where rawCandidate.family == family {
                try Task.checkCancellation()
                let generatedPath = generatedConfigurationPath(
                    family: family,
                    relativePath: rawCandidate.relativePath
                )
                let generatedKey = collisionKey(generatedPath)
                guard !plannedPathKeys.contains(generatedKey),
                      generatedPathKeys.insert(generatedKey).inserted else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "Generated registration collides with archive destination \(generatedPath)."
                    )
                }

                let exactInstalledContent = installedContent.first { content in
                    guard content.family == family,
                          let installedPath = content.registrationRelativePath else {
                        return false
                    }
                    return collisionKey(installedPath) == collisionKey(rawCandidate.relativePath)
                }
                let proposedInitials: String
                if let exactInstalledContent {
                    proposedInitials = exactInstalledContent.initials
                } else if family == .background {
                    proposedInitials = availableBackgroundInitials(
                        displayName: rawCandidate.displayName,
                        registry: registry
                    )
                } else {
                    proposedInitials = rawCandidate.baseInitials
                }
                try validateConfigToken(proposedInitials, field: "module initials")

                let provisionalDisplayName: String
                switch family {
                case .myBible, .mySword, .eSword, .epub:
                    provisionalDisplayName = ""
                default:
                    provisionalDisplayName = rawCandidate.displayName
                }
                let content = AndroidModuleBackupInstalledContent(
                    initials: proposedInitials,
                    displayName: provisionalDisplayName,
                    language: "",
                    family: family,
                    registrationRelativePath: rawCandidate.relativePath
                )
                if let exactInstalledContent {
                    guard SQLiteDocumentIdentity(exactInstalledContent.initials)
                            == SQLiteDocumentIdentity(proposedInitials),
                          registry.replace(content, replacing: exactInstalledContent) else {
                        continue
                    }
                } else {
                    guard registry.claim(content) else { continue }
                }
                appendArchiveContent(content, to: &archiveContent)
                candidates.append(AndroidModuleBackupRegistrationCandidate(
                    family: family,
                    relativePath: rawCandidate.relativePath,
                    initials: proposedInitials,
                    displayName: rawCandidate.displayName,
                    configurationRelativePath: generatedPath
                ))
            }
        }

        return AndroidModuleBackupRegistrationPreview(
            installedContent: installedContent,
            archiveContent: archiveContent,
            candidates: candidates,
            acceptedSwordConfigurationPaths: acceptedSwordConfigurationPaths
        )
    }

    /**
     Opens staged payloads and writes generated activation configs into the same staging tree.

     - Parameters:
       - preview: Pre-extraction identity allocation bound to inspection conflicts.
       - stagingDirectory: Isolated exact-overlay staging root containing archive files.
       - epubValidator: Optional full EPUB validator that publishes only into disposable scratch.
     - Returns: Metadata-validated, globally identity-arbitrated rows and generated config paths.
     - Side effects: Opens staged payloads read-only and writes generated configs only beneath
       `stagingDirectory`.
     - Throws: Cancellation or staging filesystem errors. Candidate reader/metadata failures become
       diagnostics and do not hide valid supported-family siblings. Live state is untouched.
     */
    internal func prepare(
        preview: AndroidModuleBackupRegistrationPreview,
        stagingDirectory: URL,
        epubValidator: ((URL) throws -> Void)? = nil
    ) throws -> AndroidModuleBackupPreparedRegistration {
        var registry = AndroidModuleBackupIdentityRegistry()
        for content in preview.installedContent where content.family == .swordConfiguration {
            _ = registry.claim(content)
        }
        var preparedContent: [AndroidModuleBackupInstalledContent] = []
        for content in preview.archiveContent where content.family == .swordConfiguration {
            let exactInstalled = preview.installedContent.first {
                $0.family == .swordConfiguration
                    && SQLiteDocumentIdentity($0.initials) == SQLiteDocumentIdentity(content.initials)
            }
            let accepted: Bool
            if let exactInstalled {
                accepted = registry.replace(content, replacing: exactInstalled)
            } else {
                accepted = registry.claim(content)
            }
            if accepted {
                appendArchiveContent(content, to: &preparedContent)
            }
        }
        var preparedCandidates: [AndroidModuleBackupRegistrationCandidate] = []
        var diagnostics: [AndroidModuleBackupRestoreDiagnostic] = []
        for family in Self.customFamilyOrder {
            for content in preview.installedContent where content.family == family {
                _ = registry.claim(content)
            }
            for candidate in preview.candidates where candidate.family == family {
                try Task.checkCancellation()
                let payloadURL = stagingDirectory.appendingPathComponent(candidate.relativePath)
                let registration: RegistrationMetadata
                do {
                    registration = try registrationMetadata(
                        for: candidate,
                        payloadURL: payloadURL
                    )
                    if candidate.family == .epub {
                        try epubValidator?(payloadURL)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diagnostics.append(AndroidModuleBackupRestoreDiagnostic(
                        family: candidate.family,
                        relativePath: candidate.relativePath,
                        message: error.localizedDescription
                    ))
                    continue
                }

                let exactInstalled = preview.installedContent.first { content in
                    guard content.family == family,
                          let installedPath = content.registrationRelativePath else {
                        return false
                    }
                    return collisionKey(installedPath) == collisionKey(candidate.relativePath)
                }
                let acceptedIdentity: Bool
                if let exactInstalled {
                    acceptedIdentity = registry.replace(
                        registration.content,
                        replacing: exactInstalled
                    )
                } else {
                    acceptedIdentity = registry.claim(registration.content)
                }
                guard acceptedIdentity else {
                    diagnostics.append(AndroidModuleBackupRestoreDiagnostic(
                        family: candidate.family,
                        relativePath: candidate.relativePath,
                        message: "Installed-book initials or full name collides with an earlier registration."
                    ))
                    continue
                }

                let configurationURL = stagingDirectory.appendingPathComponent(
                    candidate.configurationRelativePath
                )
                try fileManager.createDirectory(
                    at: configurationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Task.checkCancellation()
                try Data(registration.configuration.utf8).write(
                    to: configurationURL,
                    options: .atomic
                )
                appendArchiveContent(registration.content, to: &preparedContent)
                preparedCandidates.append(candidate)
            }
        }
        return AndroidModuleBackupPreparedRegistration(
            archiveContent: preparedContent,
            candidates: preparedCandidates,
            diagnostics: diagnostics
        )
    }
}

/** Candidate discovery and shared Android identity allocation. */
private extension AndroidModuleBackupRegistrationBuilder {
    /// Path-derived candidate before first-winner identity allocation.
    struct RawCandidate {
        let family: AndroidModuleBackupContentFamily
        let relativePath: String
        let baseInitials: String
        let displayName: String
    }

    /** Discovers unowned raw-family members in Android registration and deterministic path order. */
    func discoveredCandidates(plan: AndroidModuleBackupArchivePlan) throws -> [RawCandidate] {
        let unownedEntries = plan.entries.filter { $0.owningConfigurationPaths.isEmpty }
        var result: [RawCandidate] = []

        for family in Self.customFamilyOrder {
            try Task.checkCancellation()
            if family == .epub {
                var seenRoots = Set<String>()
                let roots = unownedEntries.compactMap { entry -> String? in
                    guard entry.family == .epub else { return nil }
                    let components = entry.relativePath.split(separator: "/").map(String.init)
                    guard components.count > 2 else { return nil }
                    let root = components.prefix(2).joined(separator: "/")
                    return seenRoots.insert(collisionKey(root)).inserted ? root : nil
                }.sorted()
                for root in roots {
                    let displayName = String(root.split(separator: "/")[1])
                    result.append(RawCandidate(
                        family: .epub,
                        relativePath: root,
                        baseInitials: EpubReader.initials(forDisplayFileName: displayName),
                        displayName: displayName
                    ))
                }
                continue
            }

            let matching = unownedEntries.filter { entry in
                guard entry.family == family else { return false }
                let fileName = (entry.relativePath as NSString).lastPathComponent
                let fileExtension = (fileName as NSString).pathExtension.lowercased()
                switch family {
                case .myBible:
                    return fileExtension == "sqlite3"
                case .mySword:
                    return fileName.lowercased().hasSuffix(".mybible")
                case .eSword:
                    return entry.relativePath.split(separator: "/").count == 2
                        && ["bblx", "bbli"].contains(fileExtension)
                case .ttf:
                    return fileExtension == "ttf"
                case .background:
                    return Self.backgroundExtensions.contains(fileExtension)
                case .prompts:
                    return entry.relativePath.split(separator: "/").count == 2
                        && fileExtension == "csv"
                case .epub, .swordConfiguration, .swordPayload:
                    return false
                }
            }.sorted { $0.relativePath < $1.relativePath }

            for entry in matching {
                let fileName = (entry.relativePath as NSString).lastPathComponent
                let baseName = (fileName as NSString).deletingPathExtension
                let initials: String
                switch family {
                case .myBible:
                    initials = "MyBible-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
                case .mySword:
                    initials = "MySword-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
                case .eSword:
                    initials = "ESword-" + SQLiteDocumentIdentity.sanitizedESwordModuleName(baseName)
                case .ttf:
                    initials = "TTF_\(baseName)"
                case .background:
                    initials = "BGIMG_" + androidSyntheticModuleSuffix(baseName)
                case .prompts:
                    initials = "Prompts_\(baseName)"
                case .epub, .swordConfiguration, .swordPayload:
                    continue
                }
                result.append(RawCandidate(
                    family: family,
                    relativePath: entry.relativePath,
                    baseInitials: initials,
                    displayName: baseName
                ))
            }
        }
        return result
    }

    /** Returns a deterministic config path that cannot expose archive text as a filename. */
    func generatedConfigurationPath(
        family: AndroidModuleBackupContentFamily,
        relativePath: String
    ) -> String {
        let identity = Data("\(family.rawValue)\0\(relativePath)".utf8)
        let digest = ArchiveFingerprint.sha256Hex(of: identity).prefix(32)
        return "mods.d/andbible-ios-\(family.rawValue.lowercased())-\(digest).conf"
    }

    /** Reuses a prior iOS registration only when both family and exact backing path match. */
    func existingGeneratedRegistrationInitials(
        family: AndroidModuleBackupContentFamily,
        relativePath: String,
        configurationRelativePath: String
    ) -> String? {
        let configurationURL = moduleDirectory.appendingPathComponent(configurationRelativePath)
        guard let source = try? ZipArchiveWriterPinnedFileSource(fileURL: configurationURL),
              source.byteCount <= UInt64(Self.maximumRegistrationConfigurationByteCount),
              let data = try? source.boundedData(
                maximumByteCount: Self.maximumRegistrationConfigurationByteCount
              ),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        var section: String?
        var storedFamily: String?
        var storedPath: String?
        var generated = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if section == nil, line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.caseInsensitiveCompare("AndBibleIOSGeneratedRegistration") == .orderedSame {
                generated = value.caseInsensitiveCompare("true") == .orderedSame
            } else if key.caseInsensitiveCompare("AndBibleIOSRegistrationFamily") == .orderedSame {
                storedFamily = value
            } else if key.caseInsensitiveCompare("AndBibleIOSRegistrationPath") == .orderedSame {
                storedPath = value
            }
        }
        guard generated,
              storedFamily == family.rawValue,
              storedPath == relativePath,
              let section,
              !section.isEmpty else {
            return nil
        }
        return section
    }

    /** Allocates Android's base, `_2`, `_3`, ... background identity sequence. */
    func availableBackgroundInitials(
        displayName: String,
        registry: AndroidModuleBackupIdentityRegistry
    ) -> String {
        let base = "BGIMG_" + androidSyntheticModuleSuffix(displayName)
        guard registry.content(matching: base) == nil else {
            var suffix = 2
            while registry.content(matching: "\(base)_\(suffix)") != nil {
                suffix += 1
            }
            return "\(base)_\(suffix)"
        }
        return base
    }

    /** Mirrors Android's background filename tokenization. */
    func androidSyntheticModuleSuffix(_ value: String) -> String {
        let mapped = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return mapped.isEmpty ? "image" : mapped
    }

    /** Appends one archive row once under Java-compatible initials matching. */
    func appendArchiveContent(
        _ content: AndroidModuleBackupInstalledContent,
        to rows: inout [AndroidModuleBackupInstalledContent]
    ) {
        let identity = SQLiteDocumentIdentity(content.initials)
        guard !rows.contains(where: { SQLiteDocumentIdentity($0.initials) == identity }) else {
            return
        }
        rows.append(content)
    }

    /** Matches module-store destination collision semantics. */
    func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}

/** Payload validation and exact generated-config rendering. */
private extension AndroidModuleBackupRegistrationBuilder {
    /// Validated content row paired with its generated configuration text.
    struct RegistrationMetadata {
        let content: AndroidModuleBackupInstalledContent
        let configuration: String
    }

    /** Builds one generated registration from the staged payload's authoritative metadata. */
    func registrationMetadata(
        for candidate: AndroidModuleBackupRegistrationCandidate,
        payloadURL: URL
    ) throws -> RegistrationMetadata {
        switch candidate.family {
        case .myBible:
            return try databaseRegistration(candidate: candidate, metadata: MyBibleReader(
                fileURL: payloadURL
            ).metadata)
        case .mySword:
            return try databaseRegistration(candidate: candidate, metadata: MySwordReader(
                fileURL: payloadURL
            ).metadata)
        case .eSword:
            return try databaseRegistration(candidate: candidate, metadata: ESwordReader(
                fileURL: payloadURL
            ).metadata)
        case .epub:
            let metadata = try EpubReader.androidModuleMetadata(
                epubDirectoryURL: payloadURL
            )
            let content = AndroidModuleBackupInstalledContent(
                initials: candidate.initials,
                displayName: metadata.title,
                language: metadata.language,
                family: .epub,
                registrationRelativePath: candidate.relativePath
            )
            return RegistrationMetadata(
                content: content,
                configuration: try commonConfiguration(
                    candidate: candidate,
                    description: metadata.title,
                    category: "Generic Books",
                    driver: "EpubBook",
                    dataPath: "./\(candidate.relativePath)/",
                    extraLines: [
                        "About=\(try configValue(metadata.description))",
                        "Lang=\(try configValue(metadata.language))",
                        "AndBibleEpubModule=1",
                        "AndBibleEpubDir=\(try configValue(candidate.relativePath))",
                    ]
                )
            )
        case .ttf:
            let fileName = (candidate.relativePath as NSString).lastPathComponent
            let content = AndroidModuleBackupInstalledContent(
                initials: candidate.initials,
                displayName: candidate.displayName,
                language: "",
                family: .ttf,
                registrationRelativePath: candidate.relativePath
            )
            return RegistrationMetadata(
                content: content,
                configuration: try commonConfiguration(
                    candidate: candidate,
                    description: candidate.displayName,
                    category: "And Bible",
                    driver: "RawGenBook",
                    dataPath: dataPathForBackingFile(candidate.relativePath),
                    extraLines: [
                        "AndBibleProvidesFont=\(try configValue(candidate.displayName));\(try configValue(fileName))",
                        "AndBibleIOSManualTtf=true",
                        "AndBibleMinimumVersion=892",
                    ]
                )
            )
        case .background:
            let fileName = (candidate.relativePath as NSString).lastPathComponent
            let content = AndroidModuleBackupInstalledContent(
                initials: candidate.initials,
                displayName: candidate.displayName,
                language: "",
                family: .background,
                registrationRelativePath: candidate.relativePath
            )
            return RegistrationMetadata(
                content: content,
                configuration: try commonConfiguration(
                    candidate: candidate,
                    description: candidate.displayName,
                    category: "And Bible",
                    driver: "RawGenBook",
                    dataPath: dataPathForBackingFile(candidate.relativePath),
                    extraLines: [
                        "AndBibleProvidesBackgroundImage=\(try configValue(candidate.displayName));\(try configValue(fileName))",
                        "AndBibleMinimumVersion=1112",
                    ]
                )
            )
        case .prompts:
            let fileName = (candidate.relativePath as NSString).lastPathComponent
            let content = AndroidModuleBackupInstalledContent(
                initials: candidate.initials,
                displayName: candidate.displayName,
                language: "",
                family: .prompts,
                registrationRelativePath: candidate.relativePath
            )
            return RegistrationMetadata(
                content: content,
                configuration: try commonConfiguration(
                    candidate: candidate,
                    description: "\(candidate.displayName) prompts",
                    category: "And Bible",
                    driver: "RawGenBook",
                    dataPath: dataPathForBackingFile(candidate.relativePath),
                    extraLines: [
                        "AndBibleProvidesPrompts=\(try configValue(fileName))",
                        "AndBibleMinimumVersion=892",
                    ]
                )
            )
        case .swordConfiguration, .swordPayload:
            throw AndroidModuleBackupError.invalidModuleLayout(
                "SWORD-owned content cannot receive a generated raw-family registration."
            )
        }
    }

    /** Renders one SQLite reader's Android identity and category into iOS custom-driver metadata. */
    func databaseRegistration(
        candidate: AndroidModuleBackupRegistrationCandidate,
        metadata: SQLiteDocumentMetadata
    ) throws -> RegistrationMetadata {
        guard SQLiteDocumentIdentity(metadata.initials) == SQLiteDocumentIdentity(candidate.initials) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Database identity \(metadata.initials) does not match \(candidate.initials)."
            )
        }
        let category: String
        let driver: String
        switch (candidate.family, metadata.category) {
        case (.myBible, .bible):
            category = "Biblical Texts"; driver = "MyBibleBible"
        case (.myBible, .commentary):
            category = "Commentaries"; driver = "MyBibleCommentary"
        case (.myBible, .dictionary):
            category = "Lexicons / Dictionaries"; driver = "MyBibleDictionary"
        case (.mySword, .bible):
            category = "Biblical Texts"; driver = "MySwordBible"
        case (.mySword, .commentary):
            category = "Commentaries"; driver = "MySwordCommentary"
        case (.mySword, .dictionary):
            category = "Lexicons / Dictionaries"; driver = "MySwordDictionary"
        case (.eSword, .bible):
            category = "Biblical Texts"; driver = "ESwordBible"
        default:
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsupported \(candidate.family.rawValue) database category \(metadata.category.rawValue)."
            )
        }
        var extraLines = [
            "Abbreviation=\(try configValue(metadata.abbreviation))",
            "AndBibleDbFile=\(try configValue(candidate.relativePath))",
            "Version=0.0",
            "LCSH=Bible",
            "SourceType=OSIS",
            "BlockType=BOOK",
            "Versification=KJVA",
        ]
        switch candidate.family {
        case .myBible: extraLines.append("AndBibleMyBibleModule=1")
        case .mySword: extraLines.append("AndBibleMySwordModule=1")
        case .eSword: extraLines.append("AndBibleESwordModule=1")
        default: break
        }
        if metadata.isStrongsDictionary {
            extraLines.append("Feature=GreekDef")
            extraLines.append("Feature=HebrewDef")
        }
        if metadata.hasStrongs {
            extraLines.append("GlobalOptionFilter=OSISStrongs")
            if candidate.family == .mySword {
                extraLines.append("GlobalOptionFilter=OSISMorph")
            }
        }
        if metadata.hasWordsOfChrist {
            extraLines.append("Feature=WordsOfChrist")
        }
        if metadata.direction == .rtl {
            extraLines.append("Direction=RtoL")
        }
        let content = AndroidModuleBackupInstalledContent(
            initials: candidate.initials,
            displayName: metadata.description.isEmpty ? candidate.displayName : metadata.description,
            language: metadata.language,
            family: candidate.family,
            registrationRelativePath: candidate.relativePath
        )
        return RegistrationMetadata(
            content: content,
            configuration: try commonConfiguration(
                candidate: candidate,
                description: content.displayName,
                category: category,
                driver: driver,
                dataPath: dataPathForBackingFile(candidate.relativePath),
                extraLines: extraLines
            )
        )
    }

    /** Renders common safe config lines plus family-specific Android metadata. */
    func commonConfiguration(
        candidate: AndroidModuleBackupRegistrationCandidate,
        description: String,
        category: String,
        driver: String,
        dataPath: String,
        extraLines: [String]
    ) throws -> String {
        var lines = [
            "[\(candidate.initials)]",
            "Description=\(try configValue(description))",
            "Category=\(category)",
            "ModDrv=\(driver)",
            "DataPath=\(try configValue(dataPath))",
            "Encoding=UTF-8",
        ]
        lines.append(contentsOf: extraLines)
        lines.append("AndBibleIOSGeneratedRegistration=true")
        lines.append("AndBibleIOSRegistrationFamily=\(candidate.family.rawValue)")
        lines.append("AndBibleIOSRegistrationPath=\(try configValue(candidate.relativePath))")
        return lines.joined(separator: "\n") + "\n"
    }

    /** Returns the generated config base path for one raw backing file. */
    func dataPathForBackingFile(_ relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? "./" : "./\(parent)/"
    }

    /** Rejects line-breaking config values that could create a second property or section. */
    func configValue(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Android module metadata contains an unsafe configuration value."
            )
        }
        return value
    }

    /** Rejects section tokens that cannot be represented by SWORD's line-oriented config grammar. */
    func validateConfigToken(_ value: String, field: String) throws {
        guard !value.isEmpty,
              !value.contains("["),
              !value.contains("]"),
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Android \(field) cannot be represented safely in a module configuration."
            )
        }
    }
}
