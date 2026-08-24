// AndroidModuleBackupExportInventory.swift — Android-compatible installed-module discovery

import Foundation
import SwordKit

/**
 One validated file-backed member of an Android module backup export.

 The path is relative to Android's modules root and is safe to pass directly to the ZIP writer.
 Construction is restricted to the inventory builder after containment and collision validation.
 */
internal struct AndroidModuleBackupExportEntry {
    /// Exact forward-slash archive destination relative to Android's modules root.
    internal let archivePath: String

    /// No-follow descriptor used for validation and the eventual one-pass ZIP stream.
    internal let source: ZipArchiveWriterPinnedFileSource

    /// Original path retained for diagnostics and archive-relative ownership checks.
    internal var fileURL: URL { source.fileURL }

    /** Opens and pins one private regular source after destination validation. */
    internal init(archivePath: String, fileURL: URL) throws {
        self.archivePath = archivePath
        self.source = try ZipArchiveWriterPinnedFileSource(fileURL: fileURL)
    }

    /** Reuses a configuration descriptor that was already bounded-read and validated. */
    internal init(archivePath: String, source: ZipArchiveWriterPinnedFileSource) {
        self.archivePath = archivePath
        self.source = source
    }
}

/**
 Complete validated export inventory with retained immutable native EPUB generations.

 The archive exporter must retain this value until ZIP writing finishes and then call
 `releaseEpubGenerations()`. File order is deterministic and already excludes the separately
 emitted Android manifest.
 */
internal struct AndroidModuleBackupExportInventory {
    /// Ordered file-backed ZIP members after the manifest.
    internal let entries: [AndroidModuleBackupExportEntry]

    /// Exported Android-compatible initials in discovery order.
    internal let moduleNames: [String]

    /// Canonical selected rows in the same order as archive module groups.
    internal let installedContent: [AndroidModuleBackupInstalledContent]

    /// Immutable native EPUB generations whose package files back `entries`.
    private let epubGenerationLocations: [EpubGenerationLocation]

    /// Library root against which every retained generation lease was acquired.
    private let epubLibraryRootURL: URL

    /**
     Creates a validated inventory returned by the discovery builder.

     - Parameters:
       - entries: Ordered, collision-free archive members.
       - moduleNames: Unique Android-compatible identities in discovery order.
       - installedContent: Canonical selected catalog rows in archive order.
       - epubGenerationLocations: Native generations retained while their files are consumed.
       - epubLibraryRootURL: Library root that owns every retained generation.
     - Side effects: none; leases have already been acquired by the builder.
     - Failure modes: This initializer cannot fail and is internal to validated discovery.
     */
    internal init(
        entries: [AndroidModuleBackupExportEntry],
        moduleNames: [String],
        installedContent: [AndroidModuleBackupInstalledContent],
        epubGenerationLocations: [EpubGenerationLocation],
        epubLibraryRootURL: URL
    ) {
        self.entries = entries
        self.moduleNames = moduleNames
        self.installedContent = installedContent
        self.epubGenerationLocations = epubGenerationLocations
        self.epubLibraryRootURL = epubLibraryRootURL
    }

    /**
     Releases every native EPUB generation after the writer has finished reading its files.

     - Side effects: Decrements EPUB generation leases and may prune superseded generations.
     - Failure modes: none; release and pruning are best-effort internal library operations.
     - Note: Call exactly once for each inventory returned by the builder.
     */
    internal func releaseEpubGenerations() {
        for location in epubGenerationLocations {
            EpubReader.releaseGeneration(location, libraryRootURL: epubLibraryRootURL)
        }
    }
}

/**
 Builds Android-emittable backup bytes from the validated installed-book catalog.

 Catalog discovery follows registration order and globally arbitrates initials/full names before
 selection. Materialization then validates only selected artifacts: ordinary SWORD ownership,
 validated SQLite readers, raw-or-published EPUB packages, and registered TTF/background files at
 any Android-discovered depth. Prompt books remain absent because Android's writer does not
 successfully emit them.
 */
internal struct AndroidModuleBackupExportInventoryBuilder {
    /// Largest installed SWORD configuration accepted for bounded metadata parsing.
    private static let maximumConfigurationByteCount = 1024 * 1024

    /// Android-supported manual background-image suffixes.
    private static let androidBackgroundImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp",
    ]

    /// Android runtime categories whose generic SWORD backup owns the `DataPath` parent.
    private static let androidParentDirectoryCategories: Set<String> = [
        "lexicons / dictionaries", "generic books", "maps",
    ]

    /// Drivers used to recover Android's parent-directory category when `Category` is absent.
    private static let androidParentDirectoryDrivers: Set<String> = [
        "rawld", "rawld4", "zld", "rawgenbook",
    ]

    /// File manager used for metadata enumeration and bounded configuration reads.
    private let fileManager: FileManager

    /// Canonical module root whose relative layout becomes Android archive paths.
    private let moduleDirectory: URL

    /// Optional native EPUB library override used by isolated hosts and tests.
    private let epubLibraryRootURL: URL?

    /// Installed-layout containment validator shared with module publication paths.
    private let layoutResolver: ModuleStoreInstalledLayoutResolver

    /// Archive destination reserved for the manifest and unavailable to installed payloads.
    private let reservedArchivePath: String

    /**
     Creates an immutable inventory builder for one installed module layout.

     - Parameters:
       - fileManager: File manager used to enumerate installed content.
       - moduleDirectory: Canonical module root mirrored into Android archive paths.
       - epubLibraryRootURL: Optional native EPUB library override.
       - reservedArchivePath: Manifest destination that installed files cannot claim.
     - Side effects: none; filesystem reads and EPUB leases begin only in `prepare(moduleNames:)`.
     - Failure modes: This initializer cannot fail.
     */
    internal init(
        fileManager: FileManager,
        moduleDirectory: URL,
        epubLibraryRootURL: URL?,
        reservedArchivePath: String
    ) {
        self.fileManager = fileManager
        self.moduleDirectory = moduleDirectory
        self.epubLibraryRootURL = epubLibraryRootURL
        self.layoutResolver = ModuleStoreInstalledLayoutResolver(
            moduleRootURL: moduleDirectory,
            fileManager: fileManager
        )
        self.reservedArchivePath = reservedArchivePath
    }

    /**
     Builds the complete selected inventory while retaining native EPUB package generations.

     - Parameter moduleNames: Optional Android-compatible initials in exact picker selection order.
       Matching and duplicate suppression use Java's exact UTF-16 `String.equals` identity; `nil`
       exports Android registration order.
     - Returns: Validated file-backed entries, stable module names, and generation leases that stay
       alive until ZIP writing finishes.
     - Side effects: Reads installed registrations and metadata, then pins only selected artifacts.
       Selected native EPUB generations are leased until ZIP writing completes.
     - Throws: Missing selected payload, unsafe path, symbolic-link, collision, EPUB, or filesystem
       errors. Unselected malformed raw candidates are omitted by their installed-book readers.
     */
    internal func prepare(moduleNames: [String]?) throws -> AndroidModuleBackupExportInventory {
        try Task.checkCancellation()
        let catalog = try installedContentCatalog()
        let selectedContent = Self.selectedContent(
            from: catalog,
            moduleNames: moduleNames
        )

        var leasedGenerations: [EpubGenerationLocation] = []
        let libraryRootURL = resolvedEpubLibraryRootURL
        var releaseLeasesOnReturn = true
        defer {
            if releaseLeasesOnReturn {
                for location in leasedGenerations {
                    EpubReader.releaseGeneration(location, libraryRootURL: libraryRootURL)
                }
            }
        }
        var accumulator = AndroidModuleBackupExportAccumulator(
            reservedArchivePath: reservedArchivePath
        )
        for content in selectedContent {
            try Task.checkCancellation()
            let module = try exportModule(
                for: content,
                libraryRootURL: libraryRootURL,
                leasedGenerations: &leasedGenerations
            )
            try accumulator.append(module)
        }

        releaseLeasesOnReturn = false
        return AndroidModuleBackupExportInventory(
            entries: accumulator.entries,
            moduleNames: accumulator.moduleNames,
            installedContent: accumulator.installedContent,
            epubGenerationLocations: leasedGenerations,
            epubLibraryRootURL: libraryRootURL
        )
    }

    /**
     Selects catalog rows using Android's exact `String.equals` identity in caller order.

     - Parameters:
       - catalog: Already-admitted installed rows in Android registration order.
       - moduleNames: Optional exact initials in caller selection order; `nil` selects the catalog.
     - Returns: First requested occurrence of every exact installed identity. Missing requests are
       omitted, preserving the exporter's existing partial-selection contract.
     - Side effects: None.
     - Failure modes: None; an empty or wholly missing selection returns an empty array so the
       exporter can publish `AndroidModuleBackupError.noExportableModules`.
     */
    internal static func selectedContent(
        from catalog: [AndroidModuleBackupInstalledContent],
        moduleNames: [String]?
    ) -> [AndroidModuleBackupInstalledContent] {
        guard let moduleNames else { return catalog }
        let contentByInitials = Dictionary(
            catalog.map { (SwordJavaExactStringIdentity($0.initials), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var selectedIdentities = Set<SwordJavaExactStringIdentity>()
        return moduleNames.compactMap { selectedName in
            let identity = SwordJavaExactStringIdentity(selectedName)
            guard selectedIdentities.insert(identity).inserted else { return nil }
            return contentByInitials[identity]
        }
    }

    /**
     Returns Android's readable installed-book catalog without materializing export artifacts.

     Ordinary SWORD registrations are followed by validated SQLite readers, published EPUB metadata,
     and valid recursively discovered TTF/background registrations. Prompt books are omitted because
     Android's writer does not successfully emit those sources.

     - Returns: First-winner rows using JSword initials/full-name lookup identity across families.
     - Side effects: Reads bounded metadata and SQLite files read-only; creates no scratch files,
       EPUB leases, libsword globals, generated registrations, or archive output.
     - Throws: Cancellation. Malformed registrations, SQLite files, and EPUB snapshots are skipped
       independently, matching Android's installed-book registration behavior.
     */
    internal func installedContentCatalog() throws -> [AndroidModuleBackupInstalledContent] {
        try Task.checkCancellation()
        var registry = AndroidModuleBackupIdentityRegistry()
        let registrations = ModuleStoreInstalledRegistrationReader.read(
            modulePath: moduleDirectory.path,
            fileManager: fileManager
        )
        var swordOwnership: [AndroidModuleBackupSwordConfiguration] = []
        for registration in registrations {
            try Task.checkCancellation()
            guard case .swordConfiguration = registration.ownership else { continue }
            let module = registration.moduleInfo
            _ = registry.claim(AndroidModuleBackupInstalledContent(
                initials: module.name,
                displayName: module.description.isEmpty ? module.name : module.description,
                language: module.language,
                family: .swordConfiguration,
                registrationRelativePath: registration.configurationRelativePath
            ))
            if let ownership = installedSwordOwnership(for: registration) {
                swordOwnership.append(ownership)
            }
        }

        let sqliteLibrary = SQLiteDocumentModuleLibrary(moduleRootURL: moduleDirectory)
        let sqliteFamilies: [(SQLiteDocumentFormat, AndroidModuleBackupContentFamily)] = [
            (.myBible, .myBible),
            (.mySword, .mySword),
            (.eSword, .eSword),
        ]
        for (format, family) in sqliteFamilies {
            for module in sqliteLibrary.modules where module.reader.metadata.format == format {
                try Task.checkCancellation()
                guard let relativePath = try? archivePath(for: module.reader.metadata.sourceURL)
                else { continue }
                guard !swordOwnership.contains(where: {
                    $0.ownsPayload(atRelativePath: relativePath)
                }) else {
                    continue
                }
                _ = registry.claim(AndroidModuleBackupInstalledContent(
                    initials: module.info.name,
                    displayName: module.info.description.isEmpty
                        ? module.info.name
                        : module.info.description,
                    language: module.info.language,
                    family: family,
                    registrationRelativePath: relativePath
                ))
            }
        }

        for epub in EpubReader.readOnlyInstalledEpubs(
            libraryRootURL: resolvedEpubLibraryRootURL,
            fileManager: fileManager
        ) {
            try Task.checkCancellation()
            guard let displayName = try? validatedEpubDisplayName(epub.sourceFileName) else {
                continue
            }
            _ = registry.claim(AndroidModuleBackupInstalledContent(
                initials: epub.initials,
                displayName: epub.title.isEmpty ? displayName : epub.title,
                language: epub.language,
                family: .epub,
                registrationRelativePath: "epub/\(displayName)"
            ))
        }

        for family in [AndroidModuleBackupContentFamily.ttf, .background] {
            for registration in registrations {
                try Task.checkCancellation()
                guard case .androidFamily(let rawFamily, let relativePath) = registration.ownership,
                      rawFamily == family.rawValue,
                      relativePath.split(separator: "/", omittingEmptySubsequences: false).count >= 2
                else { continue }
                let module = registration.moduleInfo
                _ = registry.claim(AndroidModuleBackupInstalledContent(
                    initials: module.name,
                    displayName: module.description.isEmpty ? module.name : module.description,
                    language: "",
                    family: family,
                    registrationRelativePath: relativePath
                ))
            }
        }
        return registry.orderedContent
    }

    /**
     Reconstructs ordinary SWORD ownership for raw-family discovery arbitration.

     - Parameter registration: Metadata-only ordinary SWORD registration already admitted by the
       side-effect-free reader.
     - Returns: Driver-aware payload ownership, or `nil` when the config changed or became unreadable
       between snapshots.
     - Side effects: Pins and bounded-reads one installed configuration; writes no files.
     - Failure modes: Any changed, malformed, oversized, or unsafe config is omitted from ownership
       arbitration and remains subject to selected-content validation during materialization.
     */
    private func installedSwordOwnership(
        for registration: ModuleStoreInstalledRegistration
    ) -> AndroidModuleBackupSwordConfiguration? {
        let relativePath = registration.configurationRelativePath
        guard relativePath.hasPrefix("mods.d/"),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).count == 2 else {
            return nil
        }
        let configURL = moduleDirectory.appendingPathComponent(relativePath)
        guard let source = try? ZipArchiveWriterPinnedFileSource(fileURL: configURL),
              let data = try? source.boundedData(
                maximumByteCount: Self.maximumConfigurationByteCount
              ) else {
            return nil
        }
        return try? parseModuleConfiguration(
            data: data,
            fallbackPath: configURL.path,
            configSource: source
        )
    }

    /**
     Reopens one selected native EPUB by both exact Android identity fields.

     - Parameters:
       - initials: Exact initials captured by installed-catalog selection.
       - sourceFileName: Exact Android source directory name captured by the catalog row.
       - installedEpubs: Fresh read-only native EPUB snapshot in registration order.
     - Returns: The first row whose initials and source filename both match by raw Java UTF-16 code
       units, or `nil` when the selected backing row disappeared or changed.
     - Side effects: None.
     - Failure modes: Canonically equivalent, case-only, missing, or otherwise changed identities
       fail closed instead of borrowing another installed EPUB generation.
     */
    internal static func installedEpub(
        matchingInitials initials: String,
        sourceFileName: String,
        in installedEpubs: [EpubInfo]
    ) -> EpubInfo? {
        installedEpubs.first {
            javaStringsAreExactlyEqual($0.initials, initials)
                && javaStringsAreExactlyEqual($0.sourceFileName, sourceFileName)
        }
    }

    /**
     Compares two Android identities with Java `String.equals` raw UTF-16 semantics.

     - Parameters:
       - lhs: First exact initials or source-filename value.
       - rhs: Second exact initials or source-filename value.
     - Returns: `true` only when both strings contain the same UTF-16 code units in the same order.
     - Side effects: None.
     - Failure modes: None; empty and malformed-scalar replacement content compare as ordinary
       Swift UTF-16 views without normalization or case folding.
     */
    internal static func javaStringsAreExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaExactStringIdentity(lhs) == SwordJavaExactStringIdentity(rhs)
    }
}

/** Selected-row materialization after read-only installed-book discovery. */
private extension AndroidModuleBackupExportInventoryBuilder {
    /**
     Pins and validates only one selected catalog row's Android-emittable artifacts.

     - Parameters:
       - content: Valid installed-book row selected by Android initials.
       - libraryRootURL: Native EPUB library used to resolve published generations.
       - leasedGenerations: Lease accumulator retained by the completed inventory.
     - Returns: One complete export module whose sources are pinned regular files.
     - Side effects: Reads selected metadata and acquires a lease for a selected native EPUB.
     - Throws: Missing, changed, malformed, escaped, symbolic-link, or unsupported selected content.
    */
    func exportModule(
        for content: AndroidModuleBackupInstalledContent,
        libraryRootURL: URL,
        leasedGenerations: inout [EpubGenerationLocation]
    ) throws -> AndroidModuleBackupExportModule {
        switch content.family {
        case .swordConfiguration:
            return try swordExportModule(for: content)
        case .myBible, .mySword, .eSword:
            return try sqliteExportModule(for: content)
        case .epub:
            return try epubExportModule(
                for: content,
                libraryRootURL: libraryRootURL,
                leasedGenerations: &leasedGenerations
            )
        case .ttf, .background:
            return try reconstructedResourceExportModule(for: content)
        case .prompts, .swordPayload:
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed content \(content.initials) has no Android-emittable backup source."
            )
        }
    }

    /** Materializes one selected ordinary SWORD config and its driver-owned payload. */
    func swordExportModule(
        for content: AndroidModuleBackupInstalledContent
    ) throws -> AndroidModuleBackupExportModule {
        guard let relativePath = content.registrationRelativePath,
              relativePath.split(separator: "/", omittingEmptySubsequences: false).count == 2,
              relativePath.hasPrefix("mods.d/"),
              (relativePath as NSString).pathExtension.caseInsensitiveCompare("conf") == .orderedSame
        else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SWORD registration for \(content.initials) has an unsafe source path."
            )
        }
        let configURL = moduleDirectory.appendingPathComponent(relativePath)
        guard try archivePath(for: configURL) == relativePath else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SWORD registration for \(content.initials) changed after discovery."
            )
        }
        let source = try ZipArchiveWriterPinnedFileSource(fileURL: configURL)
        let data: Data
        do {
            data = try source.boundedData(maximumByteCount: Self.maximumConfigurationByteCount)
        } catch {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "\(configURL.path) is not a readable SWORD config within the metadata limit."
            )
        }
        guard !isGeneratedRegistrationConfiguration(data) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SWORD registration for \(content.initials) changed family after discovery."
            )
        }
        let configuration = try parseModuleConfiguration(
            data: data,
            fallbackPath: configURL.path,
            configSource: source
        )
        guard Self.javaStringsAreExactlyEqual(configuration.moduleName, content.initials) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SWORD identity changed after selection: \(content.initials)."
            )
        }
        let payloadFiles = try swordPayloadFiles(for: configuration)
        guard !payloadFiles.isEmpty else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: configuration.moduleName,
                dataPath: configuration.dataPath
            )
        }
        let files = [AndroidModuleBackupExportEntry(
            archivePath: relativePath,
            source: source
        )] + (try payloadFiles.map { fileURL in
            try AndroidModuleBackupExportEntry(
                archivePath: try archivePath(for: fileURL),
                fileURL: fileURL
            )
        })
        return AndroidModuleBackupExportModule(content: content, files: files)
    }

    /** Reopens and pins one selected SQLite book while malformed unselected siblings stay omitted. */
    func sqliteExportModule(
        for content: AndroidModuleBackupInstalledContent
    ) throws -> AndroidModuleBackupExportModule {
        guard let relativePath = content.registrationRelativePath else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: content.initials,
                dataPath: content.family.rawValue
            )
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        let validShape: Bool
        switch content.family {
        case .myBible:
            validShape = components.count >= 2
                && components.first == "mybible"
                && fileExtension == "sqlite3"
        case .mySword:
            validShape = components.count >= 2
                && components.first == "mysword"
                && relativePath.lowercased().hasSuffix(".mybible")
        case .eSword:
            validShape = components.count == 2
                && components.first == "esword"
                && ["bblx", "bbli"].contains(fileExtension)
        default:
            validShape = false
        }
        guard validShape else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SQLite registration for \(content.initials) has an unsafe family path."
            )
        }
        let fileURL = moduleDirectory.appendingPathComponent(relativePath)
        guard try archivePath(for: fileURL) == relativePath else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed SQLite source for \(content.initials) changed after discovery."
            )
        }
        switch content.family {
        case .myBible:
            _ = try MyBibleReader(fileURL: fileURL)
        case .mySword:
            _ = try MySwordReader(fileURL: fileURL)
        case .eSword:
            _ = try ESwordReader(fileURL: fileURL)
        default:
            break
        }
        return AndroidModuleBackupExportModule(
            content: content,
            files: [try AndroidModuleBackupExportEntry(
                archivePath: relativePath,
                fileURL: fileURL
            )]
        )
    }

    /** Emits a selected raw Android EPUB tree or its immutable native package generation. */
    func epubExportModule(
        for content: AndroidModuleBackupInstalledContent,
        libraryRootURL: URL,
        leasedGenerations: inout [EpubGenerationLocation]
    ) throws -> AndroidModuleBackupExportModule {
        guard let relativePath = content.registrationRelativePath else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: content.initials,
                dataPath: "epub"
            )
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.first == "epub" else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed EPUB registration for \(content.initials) has an unsafe family path."
            )
        }
        let displayName = try validatedEpubDisplayName(String(components[1]))
        let rawRootURL = moduleDirectory.appendingPathComponent(relativePath, isDirectory: true)
        if fileManager.fileExists(atPath: rawRootURL.path) {
            guard try archivePath(for: rawRootURL) == relativePath else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Installed EPUB source for \(content.initials) changed after discovery."
                )
            }
            _ = try EpubReader.androidModuleMetadata(epubDirectoryURL: rawRootURL)
            let packageFiles = try validatedRegularFiles(under: rawRootURL, recursive: true)
            guard !packageFiles.isEmpty else {
                throw AndroidModuleBackupError.missingExportData(
                    moduleName: content.initials,
                    dataPath: relativePath
                )
            }
            return AndroidModuleBackupExportModule(
                content: content,
                files: try packageFiles.map { fileURL in
                    try AndroidModuleBackupExportEntry(
                        archivePath: try archivePath(for: fileURL),
                        fileURL: fileURL
                    )
                }
            )
        }

        let metadata = Self.installedEpub(
            matchingInitials: content.initials,
            sourceFileName: displayName,
            in: EpubReader.readOnlyInstalledEpubs(
                libraryRootURL: libraryRootURL,
                fileManager: fileManager
            )
        )
        guard let metadata,
              let location = EpubReader.acquireCurrentGeneration(
                identifier: metadata.identifier,
                libraryRootURL: libraryRootURL
              ) else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: content.initials,
                dataPath: relativePath
            )
        }
        leasedGenerations.append(location)
        let packageFiles = try validatedRegularFiles(
            under: location.packageRootURL,
            recursive: true
        )
        guard !packageFiles.isEmpty else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: content.initials,
                dataPath: relativePath
            )
        }
        return AndroidModuleBackupExportModule(
            content: content,
            files: try packageFiles.map { fileURL in
                let packagePath = try relativeExportPath(
                    of: fileURL,
                    beneath: location.packageRootURL
                )
                return try AndroidModuleBackupExportEntry(
                    archivePath: "epub/\(displayName)/\(packagePath)",
                    fileURL: fileURL
                )
            }
        )
    }

    /** Emits one selected recursively discovered TTF or background file from its registration. */
    func reconstructedResourceExportModule(
        for content: AndroidModuleBackupInstalledContent
    ) throws -> AndroidModuleBackupExportModule {
        guard let relativePath = content.registrationRelativePath else {
            throw AndroidModuleBackupError.missingExportData(
                moduleName: content.initials,
                dataPath: content.family.rawValue
            )
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let fileExtension = (relativePath as NSString).pathExtension.lowercased()
        let validShape = components.count >= 2
            && components.first == Substring(content.family.rawValue)
            && (content.family == .ttf
                ? fileExtension == "ttf"
                : Self.androidBackgroundImageExtensions.contains(fileExtension))
        guard validShape else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed resource registration for \(content.initials) has an invalid family path."
            )
        }
        let fileURL = moduleDirectory.appendingPathComponent(relativePath)
        guard try archivePath(for: fileURL) == relativePath else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Installed resource source for \(content.initials) changed after discovery."
            )
        }
        return AndroidModuleBackupExportModule(
            content: content,
            files: [try AndroidModuleBackupExportEntry(
                archivePath: relativePath,
                fileURL: fileURL
            )]
        )
    }
}

/** Cross-family Android-native file and EPUB discovery. */
private extension AndroidModuleBackupExportInventoryBuilder {
    /**
     Discovers one Android single-file family using that reader's extension and recursion rules.

     - Parameters:
       - family: Typed Android family used to derive compatible initials.
       - rootName: Literal direct-child module-root directory discovered by Android.
       - extensions: Accepted lowercase filename extensions.
       - recursive: Whether Android recursively scans descendants for this family.
       - swordConfigurations: Real SWORD ownership rules; matching payloads are never reclassified
         as synthetic custom modules.
     - Returns: One file-backed export module per matching unowned file, ordered by archive path.
     - Side effects: Enumerates filesystem metadata without reading payload bytes into memory.
     - Throws: Unsafe roots, symbolic links, case/Unicode path collisions, or metadata failures.
     */
    func customFileExportModules(
        family: AndroidModuleBackupContentFamily,
        rootName: String,
        extensions: Set<String>,
        recursive: Bool,
        swordConfigurations: [AndroidModuleBackupSwordConfiguration]
    ) throws -> [AndroidModuleBackupExportModule] {
        let rootURL = layoutResolver.canonicalRootURL.appendingPathComponent(
            rootName,
            isDirectory: true
        )
        let files = try validatedRegularFiles(under: rootURL, recursive: recursive)
        return try files.compactMap { fileURL -> AndroidModuleBackupExportModule? in
            let fileExtension = fileURL.pathExtension.lowercased(
                with: Locale(identifier: "en_US_POSIX")
            )
            guard extensions.contains(fileExtension) else { return nil }
            let destination = try archivePath(for: fileURL)
            guard !swordConfigurations.contains(where: {
                $0.ownsPayload(atRelativePath: destination)
            }) else {
                return nil
            }
            let baseName = (fileURL.lastPathComponent as NSString).deletingPathExtension
            return AndroidModuleBackupExportModule(
                content: AndroidModuleBackupInstalledContent(
                    initials: customModuleInitials(family: family, fileURL: fileURL),
                    displayName: baseName,
                    language: "",
                    family: family,
                    registrationRelativePath: destination
                ),
                files: [try AndroidModuleBackupExportEntry(
                    archivePath: destination,
                    fileURL: fileURL
                )]
            )
        }.sorted {
            $0.files[0].archivePath < $1.files[0].archivePath
        }
    }

    /**
     Derives the exact initials Android's custom-family adapters synthesize from a backing file.

     - Parameters:
       - family: Supported single-file Android family.
       - fileURL: Backing file whose final component owns the identity.
     - Returns: Android-compatible initials used by selection and export summaries.
     - Side effects: none.
     - Failure modes: Unsupported callers fall back to the file stem; production invokes this only
       for the six supported single-file families.
     */
    func customModuleInitials(
        family: AndroidModuleBackupContentFamily,
        fileURL: URL
    ) -> String {
        let fileName = fileURL.lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        switch family {
        case .myBible:
            return "MyBible-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
        case .mySword:
            return "MySword-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
        case .eSword:
            return "ESword-" + SQLiteDocumentIdentity.sanitizedESwordModuleName(baseName)
        case .ttf:
            return "TTF_\(baseName)"
        case .background:
            return "BGIMG_" + androidSyntheticModuleSuffix(baseName)
        case .prompts:
            return "Prompts_\(baseName)"
        case .epub, .swordConfiguration, .swordPayload:
            return baseName
        }
    }

    /**
     Discovers authoritative expanded Android EPUB trees directly beneath `moduleRoot/epub`.

     - Returns: One module per direct display-name directory, preserving every regular descendant.
     - Side effects: Enumerates raw package and Android optimization files without materializing
       payload bytes.
     - Throws: Empty trees, symbolic links, unsafe names, case/Unicode collisions, or filesystem
       metadata failures.
     */
    func rawEpubExportModules() throws -> [AndroidModuleBackupExportModule] {
        let rootURL = layoutResolver.canonicalRootURL.appendingPathComponent(
            "epub",
            isDirectory: true
        )
        let directories = try validatedDirectChildDirectories(under: rootURL)
        return try directories.map { directoryURL in
            let displayName = try validatedEpubDisplayName(directoryURL.lastPathComponent)
            let moduleName = EpubReader.initials(forDisplayFileName: displayName)
            let packageFiles = try validatedRegularFiles(
                under: directoryURL,
                recursive: true
            )
            guard !packageFiles.isEmpty else {
                throw AndroidModuleBackupError.missingExportData(
                    moduleName: moduleName,
                    dataPath: "epub/\(displayName)"
                )
            }
            return AndroidModuleBackupExportModule(
                content: AndroidModuleBackupInstalledContent(
                    initials: moduleName,
                    displayName: displayName,
                    language: "",
                    family: .epub,
                    registrationRelativePath: "epub/\(displayName)"
                ),
                files: try packageFiles.map { fileURL in
                    try AndroidModuleBackupExportEntry(
                        archivePath: try archivePath(for: fileURL),
                        fileURL: fileURL
                    )
                }
            )
        }.sorted { $0.moduleName < $1.moduleName }
    }

    /**
     Returns real direct-child directories below an optional Android family root.

     - Parameter rootURL: Candidate family root beneath the canonical module directory.
     - Returns: Direct child directories ordered by exact filename; a missing root yields `[]`.
     - Side effects: Reads directory metadata only.
     - Throws: A non-directory root, symbolic links, or case/Unicode-colliding child names.
     */
    func validatedDirectChildDirectories(under rootURL: URL) throws -> [URL] {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let rootValues = try rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Android family root is not a real directory: \(rootURL.path)."
            )
        }
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var namesByKey: [String: String] = [:]
        var result: [URL] = []
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Symbolic-link payload is not exportable: \(child.path)."
                )
            }
            let key = collisionKey(child.lastPathComponent)
            if let existing = namesByKey[key] {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Installed paths collide on the destination filesystem: \(existing) and \(child.lastPathComponent)."
                )
            }
            namesByKey[key] = child.lastPathComponent
            if values.isDirectory == true {
                result.append(child)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /**
     Enumerates regular files under one real directory and validates every traversed node.

     - Parameters:
       - rootURL: Family or immutable EPUB-package root.
       - recursive: Whether descendants below direct children are included.
     - Returns: Regular files in deterministic relative-path order; a missing root yields `[]`.
     - Side effects: Reads directory metadata only.
     - Throws: Non-directory roots, symbolic links, special nodes, enumeration failures, unsafe
       relative paths, or case/Unicode collisions among files and directories.
     */
    func validatedRegularFiles(under rootURL: URL, recursive: Bool) throws -> [URL] {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let rootValues = try rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export root is not a real directory: \(rootURL.path)."
            )
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let candidates: [URL]
        if recursive {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Unable to enumerate export root \(rootURL.path)."
                )
            }
            var enumerated: [URL] = []
            for case let candidate as URL in enumerator {
                try Task.checkCancellation()
                let values = try candidate.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true, values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                enumerated.append(candidate)
            }
            if let enumerationError { throw enumerationError }
            candidates = enumerated
        } else {
            candidates = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        }

        var pathsByKey: [String: String] = [:]
        var regularFiles: [(String, URL)] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let relativePath = try relativeExportPath(of: candidate, beneath: rootURL)
            let values = try candidate.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Symbolic-link payload is not exportable: \(candidate.path)."
                )
            }
            let key = collisionKey(relativePath)
            if let existing = pathsByKey[key] {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Installed paths collide on the destination filesystem: \(existing) and \(relativePath)."
                )
            }
            pathsByKey[key] = relativePath
            if values.isRegularFile == true {
                regularFiles.append((relativePath, candidate))
            } else if values.isDirectory != true {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Special-file payload is not exportable: \(candidate.path)."
                )
            }
        }
        return regularFiles.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /**
     Produces a validated relative path without resolving a descendant symbolic link.

     - Parameters:
       - fileURL: Enumerated strict descendant.
       - rootURL: Real directory that owns the descendant.
     - Returns: Forward-slash relative path preserving exact case and Unicode spelling.
     - Side effects: none.
     - Throws: `invalidModuleLayout` for escapes, empty/dot components, backslashes, or NUL bytes.
     */
    func relativeExportPath(of fileURL: URL, beneath rootURL: URL) throws -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export payload escapes its family root: \(fileURL.path)."
            )
        }
        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
        guard relativeComponents.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("\\")
                && !component.contains("\0")
        }) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export payload has an unsafe path: \(fileURL.path)."
            )
        }
        return relativeComponents.joined(separator: "/")
    }

    /**
     Validates one native or raw EPUB display-name directory component.

     - Parameter value: Exact source filename retained by EPUB metadata or the raw module tree.
     - Returns: The exact safe source component used verbatim below `epub/`.
     - Side effects: none.
     - Throws: `invalidModuleLayout` for empty, relative, separator-bearing, or NUL names.
     */
    func validatedEpubDisplayName(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsafe Android EPUB display name \(value)."
            )
        }
        return value
    }

    /**
     Resolves the native EPUB library used for generation discovery and leases.

     - Returns: Explicit isolated root or the app's Documents `epub` library.
     - Side effects: Queries the user-domain Documents directory without creating it.
     - Failure modes: Foundation provides a user-domain Documents URL for supported app hosts.
     */
    var resolvedEpubLibraryRootURL: URL {
        if let epubLibraryRootURL {
            return epubLibraryRootURL.standardizedFileURL
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("epub", isDirectory: true).standardizedFileURL
    }

    /**
     Applies Android's filename-to-synthetic-module token for background resources.

     - Parameter value: Background filename stem.
     - Returns: ASCII alphanumeric and underscore token, or `image` when no token remains.
     - Side effects: none.
     - Failure modes: none.
     */
    func androidSyntheticModuleSuffix(_ value: String) -> String {
        let mapped = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return mapped.isEmpty ? "image" : mapped
    }

    /**
     Allocates Android's first available background identity after earlier registrar winners.

     - Parameters:
       - displayName: Image filename stem used to create the base `BGIMG_` token.
       - registry: Identities already installed in Android registration order.
     - Returns: Base initials or the first `_2`, `_3`, ... suffix not already registered.
     - Side effects: none; the caller claims the returned identity after allocation.
     - Failure modes: none; suffix search terminates when the finite installed set has a gap.
     */
    func availableBackgroundInitials(
        for displayName: String,
        registry: AndroidModuleBackupIdentityRegistry
    ) -> String {
        let base = "BGIMG_" + androidSyntheticModuleSuffix(displayName)
        guard registry.content(matching: base) != nil else { return base }
        var suffix = 2
        while registry.content(matching: "\(base)_\(suffix)") != nil {
            suffix += 1
        }
        return "\(base)_\(suffix)"
    }
}

/** Driver-aware SWORD configuration parsing and payload ownership discovery. */
private extension AndroidModuleBackupExportInventoryBuilder {
    /**
     Loads real, module-root-contained SWORD configuration files for ownership discovery.

     - Returns: Parsed configurations in deterministic initials order; a missing `mods.d` yields
       an empty array.
     - Side effects: Reads direct config-file metadata and bounded configuration bytes.
     - Throws: Filesystem failures or `invalidModuleLayout` for symlinked/special config nodes,
       unsafe containment, malformed configurations, or mismatched initials.
     */
    func installedModuleConfigurations() throws -> [AndroidModuleBackupSwordConfiguration] {
        let modsDirectory = moduleDirectory.appendingPathComponent("mods.d", isDirectory: true)
        guard fileManager.fileExists(atPath: modsDirectory.path) else {
            return []
        }
        let rootValues = try modsDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "SWORD configuration root is not a real directory: \(modsDirectory.path)."
            )
        }
        do {
            try layoutResolver.validateCanonicalContainment(
                of: modsDirectory,
                beneath: layoutResolver.canonicalRootURL
            )
        } catch let error as ModuleStoreMutationError {
            throw AndroidModuleBackupError.invalidModuleLayout(error.localizedDescription)
        }
        let files = try fileManager.contentsOfDirectory(
            at: modsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        return try files
            .filter { $0.pathExtension.lowercased() == "conf" }
            .compactMap { url -> AndroidModuleBackupSwordConfiguration? in
                try Task.checkCancellation()
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "SWORD configuration is not a real file: \(url.path)."
                    )
                }
                do {
                    try layoutResolver.validateCanonicalContainment(
                        of: url,
                        beneath: layoutResolver.canonicalRootURL
                    )
                } catch let error as ModuleStoreMutationError {
                    throw AndroidModuleBackupError.invalidModuleLayout(error.localizedDescription)
                }
                let source = try ZipArchiveWriterPinnedFileSource(fileURL: url)
                let data: Data
                do {
                    data = try source.boundedData(
                        maximumByteCount: Self.maximumConfigurationByteCount
                    )
                } catch {
                    throw AndroidModuleBackupError.invalidModuleLayout(
                        "\(url.path) is not a readable SWORD config within the metadata limit."
                    )
                }
                guard !isGeneratedRegistrationConfiguration(data) else {
                    return nil
                }
                return try parseModuleConfiguration(
                    data: data,
                    fallbackPath: url.path,
                    configSource: source
                )
            }
            .sorted {
                $0.moduleName.localizedCaseInsensitiveCompare($1.moduleName) == .orderedAscending
            }
    }

    /**
     Identifies persisted metadata whose only purpose is registering an Android raw-file family.

     Android creates these books in memory and therefore never writes their synthetic metadata into
     a module backup. iOS persists equivalent configs for startup discovery, but the canonical
     exporter must skip them and let the matching raw family own exactly its Android payload.

     - Parameter data: Bounded configuration bytes read from the pinned config descriptor.
     - Returns: `true` for current generated registrations and legacy iOS manual-TTF registrations.
     - Side effects: none.
     - Failure modes: Undecodable data returns `false` and proceeds to strict real-SWORD parsing.
     */
    func isGeneratedRegistrationConfiguration(_ data: Data) -> Bool {
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return false
        }
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let generatedKey = key.caseInsensitiveCompare(
                "AndBibleIOSGeneratedRegistration"
            ) == .orderedSame
                || key.caseInsensitiveCompare("AndBibleIOSManualTtf") == .orderedSame
            if generatedKey, value.caseInsensitiveCompare("true") == .orderedSame {
                return true
            }
        }
        return false
    }

    /**
     Parses Android's generic SWORD export identity and category-owned payload root.

     - Parameters:
       - data: Bounded UTF-8 or ISO-Latin-1 configuration bytes.
       - fallbackPath: Installed config path whose filename must match the section initials.
       - configSource: Pinned descriptor that supplied `data` and will supply archive bytes.
     - Returns: Safe module-root-contained ownership used for selection and payload discovery.
     - Side effects: Reads no payload files and mutates no filesystem state.
     - Throws: `invalidModuleLayout` for malformed initials, fields, paths, or root escapes.
     */
    func parseModuleConfiguration(
        data: Data,
        fallbackPath: String,
        configSource: ZipArchiveWriterPinnedFileSource
    ) throws -> AndroidModuleBackupSwordConfiguration {
        var content = try decodedConfiguration(data, path: fallbackPath)
        if content.first == "\u{feff}" {
            content.removeFirst()
        }
        let fileName = (fallbackPath as NSString).lastPathComponent
        var moduleName: String?
        var dataPath: String?
        var driver: String?
        var category: String?
        var description: String?
        var language: String?
        var providesFonts: [String] = []
        var isIOSManualTtf = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if moduleName == nil, line.hasPrefix("["), line.hasSuffix("]") {
                let candidate = line.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    moduleName = candidate
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
            } else if key.caseInsensitiveCompare("Description") == .orderedSame, description == nil {
                description = value
            } else if key.caseInsensitiveCompare("Lang") == .orderedSame, language == nil {
                language = value
            } else if key.caseInsensitiveCompare("AndBibleProvidesFont") == .orderedSame {
                providesFonts.append(value)
            } else if key.caseInsensitiveCompare("AndBibleIOSManualTtf") == .orderedSame {
                isIOSManualTtf = value.caseInsensitiveCompare("true") == .orderedSame
            }
        }

        guard let moduleName,
              !moduleName.isEmpty,
              moduleName != ".",
              moduleName != "..",
              !moduleName.contains("/"),
              !moduleName.contains("\\"),
              !moduleName.contains("%"),
              !moduleName.contains("\0"),
              let rawDataPath = dataPath,
              !rawDataPath.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Malformed installed SWORD configuration \(fileName)."
            )
        }
        let configName = (fileName as NSString).deletingPathExtension
        guard configName.caseInsensitiveCompare(moduleName) == .orderedSame else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "SWORD configuration \(fileName) does not match module initials \(moduleName)."
            )
        }

        var lexicalDataPath = rawDataPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if lexicalDataPath.hasPrefix("./") {
            lexicalDataPath.removeFirst(2)
        }
        guard !lexicalDataPath.isEmpty,
              !lexicalDataPath.hasPrefix("/"),
              !lexicalDataPath.contains("\\"),
              !lexicalDataPath.contains("%"),
              !lexicalDataPath.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsafe SWORD DataPath in \(fileName)."
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
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsafe SWORD DataPath in \(fileName)."
            )
        }

        let normalizedDriver = (driver ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let normalizedCategory = category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let categoryOwnsParent = normalizedCategory.map {
            Self.androidParentDirectoryCategories.contains($0)
        } ?? false
        let driverInfersParent = (normalizedCategory == nil || normalizedCategory == "other")
            && Self.androidParentDirectoryDrivers.contains(normalizedDriver)
        let payloadComponents: [String]
        if categoryOwnsParent || driverInfersParent {
            guard components.count > 1 else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "SWORD DataPath has no category-owned parent in \(fileName)."
                )
            }
            payloadComponents = Array(components.dropLast())
        } else {
            payloadComponents = components
        }
        let payloadRootRelativePath = payloadComponents.joined(separator: "/")
        guard payloadComponents.first.map(collisionKey) != "mods.d",
              collisionKey(payloadRootRelativePath) != collisionKey(reservedArchivePath) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "SWORD DataPath targets a reserved export destination in \(fileName)."
            )
        }
        let payloadRootURL = payloadComponents.reduce(layoutResolver.canonicalRootURL) {
            $0.appendingPathComponent($1)
        }
        do {
            try layoutResolver.validateCanonicalContainment(
                of: payloadRootURL,
                beneath: layoutResolver.canonicalRootURL
            )
        } catch let error as ModuleStoreMutationError {
            throw AndroidModuleBackupError.invalidModuleLayout(error.localizedDescription)
        }
        let manualTtfRelativePath: String?
        if isIOSManualTtf {
            guard normalizedDriver == "rawgenbook",
                  normalizedCategory == "and bible",
                  components.first.map(collisionKey) == "ttf",
                  providesFonts.count == 1,
                  let semicolon = providesFonts[0].firstIndex(of: ";") else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Malformed manual TTF ownership in \(fileName)."
                )
            }
            let rawFilePath = providesFonts[0][providesFonts[0].index(after: semicolon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fontComponents = rawFilePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard !fontComponents.isEmpty,
                  fontComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !rawFilePath.contains("\\"),
                  !rawFilePath.contains("\0") else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Unsafe manual TTF ownership in \(fileName)."
                )
            }
            manualTtfRelativePath = (components + fontComponents).joined(separator: "/")
        } else {
            manualTtfRelativePath = nil
        }
        return AndroidModuleBackupSwordConfiguration(
            moduleName: moduleName,
            dataPath: components.joined(separator: "/"),
            configSource: configSource,
            displayName: description?.isEmpty == false ? description! : moduleName,
            language: language ?? "",
            manualTtfRelativePath: manualTtfRelativePath,
            payloadRootRelativePath: payloadRootRelativePath,
            payloadRootURL: payloadRootURL
        )
    }

    /**
     Decodes one bounded installed SWORD configuration.

     - Parameters:
       - data: Raw configuration bytes.
       - path: Source path included in validation failures.
     - Returns: UTF-8 or ISO-Latin-1 configuration text.
     - Side effects: none.
     - Throws: `invalidModuleLayout` when the metadata limit or supported encodings are violated.
     */
    func decodedConfiguration(_ data: Data, path: String) throws -> String {
        guard data.count <= Self.maximumConfigurationByteCount,
              let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "\(path) is not a readable SWORD config within the metadata limit."
            )
        }
        return content
    }

    /**
     Returns exactly the regular payload files owned by one driver-aware installed layout.

     - Parameter configuration: Parsed SWORD configuration and canonical ownership rule.
     - Returns: Driver-owned regular files in deterministic archive order, or `[]` when absent.
     - Side effects: Enumerates payload metadata without reading file contents.
     - Throws: Filesystem errors or `invalidModuleLayout` for symbolic-link payload directories.
     */
    func swordPayloadFiles(
        for configuration: AndroidModuleBackupSwordConfiguration
    ) throws -> [URL] {
        try regularFiles(under: configuration.payloadRootURL)
    }

    /**
     Lists regular files below one local SWORD payload path in deterministic archive order.

     - Parameter url: Canonical driver-owned payload file or directory.
     - Returns: Every regular payload descendant, or `[]` when the path is absent.
     - Side effects: Enumerates filesystem metadata without reading payload bytes.
     - Throws: Filesystem, containment, special-file, or symbolic-link validation failures.
     */
    func regularFiles(under url: URL) throws -> [URL] {
        try Task.checkCancellation()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        let rootValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Symbolic-link payload is not exportable: \(url.path)."
            )
        }
        if !isDirectory.boolValue {
            guard rootValues.isRegularFile == true else {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Special-file payload is not exportable: \(url.path)."
                )
            }
            try layoutResolver.validateCanonicalContainment(
                of: url,
                beneath: layoutResolver.canonicalRootURL
            )
            return [url]
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Symbolic-link payload is not exportable: \(fileURL.path)."
                )
            }
            if values.isRegularFile == true {
                try layoutResolver.validateCanonicalContainment(
                    of: fileURL,
                    beneath: layoutResolver.canonicalRootURL
                )
                files.append(fileURL)
            }
        }
        return files.sorted {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
    }

    /**
     Converts a local module file URL into an Android module-backup archive path.

     - Parameter fileURL: Existing config or payload URL beneath the canonical module root.
     - Returns: Exact module-root-relative path with forward-slash separators.
     - Side effects: Resolves filesystem containment without modifying files.
     - Throws: `invalidModuleLayout` when the source escapes the canonical module root.
     */
    func archivePath(for fileURL: URL) throws -> String {
        try layoutResolver.validateCanonicalContainment(
            of: fileURL,
            beneath: layoutResolver.canonicalRootURL
        )
        let rootPath = layoutResolver.canonicalRootURL.path
        let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix("\(rootPath)/") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "\(fileURL.path) is outside the module directory."
            )
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /**
     Produces the destination filesystem comparison key used for selection and collisions.

     - Parameter value: Module identity or archive path.
     - Returns: Canonically composed, POSIX-lowercased comparison key.
     - Side effects: none.
     - Failure modes: none.
     */
    func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}

/** One selectable Android-compatible identity and every archive member it owns. */
private struct AndroidModuleBackupExportModule {
    /// Shared Android runtime identity and presentation metadata.
    let content: AndroidModuleBackupInstalledContent

    /// Android-compatible initials used by selection and result summaries.
    var moduleName: String { content.initials }

    /// Config/payload or custom-family files emitted when this identity is selected.
    let files: [AndroidModuleBackupExportEntry]

    /** Returns the same owned files under a newly allocated Android runtime identity. */
    func replacingInitials(_ initials: String) -> AndroidModuleBackupExportModule {
        AndroidModuleBackupExportModule(
            content: AndroidModuleBackupInstalledContent(
                initials: initials,
                displayName: content.displayName,
                language: content.language,
                family: content.family,
                registrationRelativePath: content.registrationRelativePath
            ),
            files: files
        )
    }
}

/**
 Captures one parsed SWORD configuration and the payload subtree Android assigns to its driver.

 Values are immutable after parsing. Construction occurs only after initials, paths, and canonical
 containment have been validated by the inventory builder.
 */
private struct AndroidModuleBackupSwordConfiguration {
    /// Module initials from the config section and matching config filename.
    let moduleName: String

    /// Normalized archive-relative `DataPath` used in missing-payload failures.
    let dataPath: String

    /// Real installed configuration descriptor emitted with the owned payload.
    let configSource: ZipArchiveWriterPinnedFileSource

    /// User-visible SWORD description used by the canonical picker catalog.
    let displayName: String

    /// SWORD language code used by Android's backup picker ordering.
    let language: String

    /// Exact manually generated TTF payload path, or nil for real SWORD/font-pack ownership.
    let manualTtfRelativePath: String?

    /// Real installed configuration path retained for archive destination derivation.
    var fileURL: URL { configSource.fileURL }

    /// Archive-relative root owned by the driver, including category-based parent expansion.
    let payloadRootRelativePath: String

    /// Canonical local file or directory from which the driver's payload is exported.
    let payloadRootURL: URL

    /**
     Reports whether an archive destination belongs to this SWORD driver's payload subtree.

     - Parameter path: Validated archive-relative destination to classify.
     - Returns: `true` for the ownership root itself or any descendant, compared using destination
       filesystem case-insensitive and Unicode-normalized semantics.
     - Side effects: none.
     - Failure modes: none; the comparison does not access the filesystem.
     */
    func ownsPayload(atRelativePath path: String) -> Bool {
        if let manualTtfRelativePath {
            return Self.collisionKey(path) == Self.collisionKey(manualTtfRelativePath)
        }
        let rootKey = Self.collisionKey(payloadRootRelativePath)
        let pathKey = Self.collisionKey(path)
        return pathKey == rootKey || pathKey.hasPrefix(rootKey + "/")
    }

    /** Returns the deterministic destination-filesystem comparison key for ownership checks. */
    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}

/**
 Validates module identities and archive destinations while preserving append order.

 The directory index acts as a path trie: it rejects duplicate files, file/child conflicts, and
 case- or Unicode-equivalent spellings before any ZIP destination is opened.
 */
private struct AndroidModuleBackupExportAccumulator {
    /// Accepted file-backed entries in final ZIP order after the manifest.
    private(set) var entries: [AndroidModuleBackupExportEntry] = []

    /// Accepted module initials in append order.
    private(set) var moduleNames: [String] = []

    /// Canonical selected content in the same order as archive module groups.
    private(set) var installedContent: [AndroidModuleBackupInstalledContent] = []

    /// First file spelling for each normalized destination.
    private var filePathsByKey: [String: String]

    /// First directory spelling for each normalized destination prefix.
    private var directoryPathsByKey: [String: String] = [:]

    /**
     Creates an empty inventory with the reserved manifest destination already occupied.

     - Parameter reservedArchivePath: Literal first-entry path unavailable to installed files.
     - Side effects: Initializes only in-memory collision indexes.
     - Failure modes: none; the archive exporter supplies a validated constant path.
     */
    init(reservedArchivePath: String) {
        filePathsByKey = [Self.collisionKey(reservedArchivePath): reservedArchivePath]
    }

    /**
     Appends one complete selectable module after validating its identity and destinations.

     - Parameter module: Non-empty module candidate backed by existing files.
     - Side effects: Mutates this in-memory inventory only.
     - Throws: `invalidModuleLayout` for empty identities/files, unsafe paths, duplicate
       destinations, file/directory overlap, or normalized path collisions. Android identity
       first-winner filtering occurs before this destination accumulator.
     */
    mutating func append(_ module: AndroidModuleBackupExportModule) throws {
        guard !module.moduleName.isEmpty, !module.files.isEmpty else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export module identity or payload is empty."
            )
        }
        for file in module.files {
            try append(file)
        }
        moduleNames.append(module.moduleName)
        installedContent.append(module.content)
    }

    /**
     Validates and appends one file destination to the path trie.

     - Parameter file: File-backed member owned by the module currently being appended.
     - Side effects: Mutates file and directory collision indexes after validation.
     - Throws: `invalidModuleLayout` for unsafe, duplicate, normalized-colliding, or overlapping
       file and directory destinations.
     */
    private mutating func append(_ file: AndroidModuleBackupExportEntry) throws {
        let components = try Self.validatedComponents(file.archivePath)
        var parentComponents: [String] = []
        for component in components.dropLast() {
            parentComponents.append(component)
            let parentPath = parentComponents.joined(separator: "/")
            let parentKey = Self.collisionKey(parentPath)
            if let filePath = filePathsByKey[parentKey] {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Export destinations conflict: \(filePath) and \(file.archivePath)."
                )
            }
            if let existing = directoryPathsByKey[parentKey], existing != parentPath {
                throw AndroidModuleBackupError.invalidModuleLayout(
                    "Export directories collide on the destination filesystem: \(existing) and \(parentPath)."
                )
            }
            directoryPathsByKey[parentKey] = parentPath
        }

        let fileKey = Self.collisionKey(file.archivePath)
        if let existing = filePathsByKey[fileKey] {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export destinations collide: \(existing) and \(file.archivePath)."
            )
        }
        if let existing = directoryPathsByKey[fileKey] {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Export destinations conflict: \(existing) and \(file.archivePath)."
            )
        }
        filePathsByKey[fileKey] = file.archivePath
        entries.append(file)
    }

    /**
     Returns safe non-empty path components while preserving exact spelling.

     - Parameter path: Candidate module-root-relative ZIP destination.
     - Returns: Exact components when the path is safe for Android and Apple filesystems.
     - Side effects: none.
     - Throws: `invalidModuleLayout` for absolute, empty, dot, slash-variant, or NUL paths.
     */
    private static func validatedComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsafe export destination \(path)."
            )
        }
        let components = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AndroidModuleBackupError.invalidModuleLayout(
                "Unsafe export destination \(path)."
            )
        }
        return components
    }

    /**
     Matches Apple destination semantics for module initials and archive paths.

     - Parameter value: Module identity or complete destination prefix.
     - Returns: Canonically composed, POSIX-lowercased comparison key.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
    }
}
