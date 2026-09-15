import Foundation
import SQLite3
import SwiftData
import BibleCore
import SwordKit

/**
 Host-side fixture writer for XCUITests.

 The tool operates directly on the simulator app data container instead of relying on production
 harness UI. It can reset persisted state, seed deterministic fixture graphs into the same
 SwiftData store files the real app uses, and emit preferences for the app to apply on launch.
 */
@main
struct UITestFixtureTool {
    /**
     Parses command-line arguments and runs the requested fixture command.
     *
     * - Throws: `FixtureToolError` when the caller supplies invalid arguments or the requested
     *   container/scenario cannot be prepared.
     */
    static func main() throws {
        let arguments = try ToolArguments(arguments: Array(CommandLine.arguments.dropFirst()))
        let tool = FixtureTool(arguments: arguments)
        try tool.run()
    }
}

/// Supported top-level fixture tool commands.
private enum ToolCommand: String {
    case reset
    case seed
}

/// Deterministic fixture scenarios used by the UI automation suite.
private enum FixtureScenario: String, CaseIterable {
    case baseline = "baseline"
    case performanceBookmarks10 = "performance-bookmarks-10"
    case performanceBookmarks1000 = "performance-bookmarks-1000"
    case performanceBookmarks10000 = "performance-bookmarks-10000"
    case baselineThreeWindows = "baseline-three-windows"
    case commentaryModule = "commentary-module"
    case commentaryModuleThreeWindows = "commentary-module-three-windows"
    case searchIndexed = "search-indexed"
    case searchCompletePreview = "search-complete-preview"
    case searchCompletePreviewMulti = "search-complete-preview-multi"
    case searchMultiTranslation = "search-multi-translation"
    case documentSwitchCustomTheme = "document-switch-custom-theme"
    case documentSwitchCustomNightTheme = "document-switch-custom-night-theme"
    case bookmarkNavigation = "bookmark-navigation"
    case bookmarkNavigationThreeWindows = "bookmark-navigation-three-windows"
    case bookmarkMultiRow = "bookmark-multirow"
    case bookmarkFilter = "bookmark-filter"
    case bookmarkRowLabel = "bookmark-row-label"
    case bookmarkGenericVisible = "bookmark-generic-visible"
    case bookmarkStudyPad = "bookmark-studypad"
    case historyMultiRow = "history-multirow"
    case myNotesSingle = "my-notes-single"
    case myDocumentsSingle = "my-documents-single"
    case localQuickDocuments = "local-quick-documents"
    case longBibleQuickSelector = "long-bible-quick-selector"
    case syncNextCloud = "sync-nextcloud"
    case syncNextCloudBookmarksEnabled = "sync-nextcloud-bookmarks-enabled"
    case displayColorsCustom = "display-colors-custom"
    case readerNightMode = "reader-night-mode"
    case downloadsRowOrder = "downloads-row-order"
    case lockedPickerDownloads = "locked-picker-downloads"
    case lockedReadableNext = "locked-readable-next"
    case lockedSuggestedCommentary = "locked-suggested-commentary"
    case lockedStartupQueue = "locked-startup-queue"
}

/// Parsed CLI arguments for one fixture-tool invocation.
private struct ToolArguments {
    let command: ToolCommand
    let dataContainerURL: URL
    let bundleIdentifier: String
    let scenario: FixtureScenario?
    let swordFixtureURL: URL?

    /**
     Parses the raw CLI argument array.
     *
     * Expected forms:
     * - `reset --data-container /path --bundle-id org.andbible.ios`
     * - `seed --data-container /path --scenario bookmark-navigation --bundle-id org.andbible.ios`
     *
     * - Parameter arguments: Raw CLI arguments excluding the executable path.
     * - Throws: `FixtureToolError` when required flags are missing or invalid.
     */
    init(arguments: [String]) throws {
        guard let commandToken = arguments.first,
              let command = ToolCommand(rawValue: commandToken) else {
            throw FixtureToolError.usage(
                "Expected first argument to be one of: \(ToolCommand.reset.rawValue), \(ToolCommand.seed.rawValue)"
            )
        }

        var dataContainerPath: String?
        var bundleIdentifier = "org.andbible.ios"
        var scenario: FixtureScenario?
        var swordFixtureURL: URL?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--data-container":
                index += 1
                guard index < arguments.count else {
                    throw FixtureToolError.usage("Missing value for --data-container")
                }
                dataContainerPath = arguments[index]
            case "--bundle-id":
                index += 1
                guard index < arguments.count else {
                    throw FixtureToolError.usage("Missing value for --bundle-id")
                }
                bundleIdentifier = arguments[index]
            case "--scenario":
                index += 1
                guard index < arguments.count else {
                    throw FixtureToolError.usage("Missing value for --scenario")
                }
                guard let parsedScenario = FixtureScenario(rawValue: arguments[index]) else {
                    let validScenarios = FixtureScenario.allCases.map(\.rawValue).joined(separator: ", ")
                    throw FixtureToolError.usage("Unknown scenario '\(arguments[index])'. Valid values: \(validScenarios)")
                }
                scenario = parsedScenario
            case "--sword-fixture-path":
                index += 1
                guard index < arguments.count else {
                    throw FixtureToolError.usage("Missing value for --sword-fixture-path")
                }
                swordFixtureURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default:
                throw FixtureToolError.usage("Unknown argument '\(argument)'")
            }
            index += 1
        }

        guard let dataContainerPath else {
            throw FixtureToolError.usage("Missing required --data-container argument")
        }
        if command == .seed && scenario == nil {
            throw FixtureToolError.usage("Missing required --scenario argument for seed command")
        }

        self.command = command
        self.dataContainerURL = URL(fileURLWithPath: dataContainerPath, isDirectory: true)
        self.bundleIdentifier = bundleIdentifier
        self.scenario = scenario
        self.swordFixtureURL = swordFixtureURL
    }
}

/// High-level errors emitted by the fixture tool.
private enum FixtureToolError: LocalizedError {
    case usage(String)
    case sqlite(String)
    case missingSwordFixtureResources(String)
    case missingSwordModule(String)
    case unresolvedVerse(String)
    case missingWorkspace
    case missingWindow
    case missingPageManager

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .sqlite(let message):
            return message
        case .missingSwordFixtureResources(let path):
            return "Fixture seeding could not find SWORD fixture resources at '\(path)'."
        case .missingSwordModule(let moduleName):
            return "Fixture seeding could not load required SWORD module '\(moduleName)'."
        case .unresolvedVerse(let reference):
            return "Fixture seeding could not resolve required SWORD verse '\(reference)'."
        case .missingWorkspace:
            return "Fixture seeding could not resolve or create an active workspace."
        case .missingWindow:
            return "Fixture seeding could not resolve or create an active window."
        case .missingPageManager:
            return "Fixture seeding could not resolve or create a page manager."
        }
    }
}

/// Filesystem layout for the simulator app data container.
private struct FixturePaths {
    let dataContainerURL: URL
    let applicationSupportURL: URL
    let documentsURL: URL
    let cloudStoreURL: URL
    let localStoreURL: URL

    /**
     Creates the derived simulator-container paths used by the tool.
     *
     * - Parameter dataContainerURL: Root data container returned by
     *   `simctl get_app_container ... data`.
     */
    init(dataContainerURL: URL) {
        self.dataContainerURL = dataContainerURL
        self.applicationSupportURL = dataContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        self.documentsURL = dataContainerURL.appendingPathComponent("Documents", isDirectory: true)
        self.cloudStoreURL = applicationSupportURL.appendingPathComponent("AndBible.store", isDirectory: false)
        self.localStoreURL = applicationSupportURL.appendingPathComponent("LocalStore.store", isDirectory: false)
    }

    /**
     Verifies that Foundation and SwordKit adopted the requested simulator app container.

     `EpubReader` intentionally uses the process-default Documents and SWORD roots. The macOS
     fixture service redirects those defaults with `CFFIXED_USER_HOME`, but this executable may
     also be invoked directly. Failing before any default-root EPUB mutation prevents a missing or
     ignored redirect from reading or deleting a host-library identity.

     - Side effects: Resolves filesystem symlinks for path comparison only.
     - Throws: `FixtureToolError.usage` unless both default roots exactly match the requested
       container's `Documents` and `Documents/sword` paths.
     */
    func validateDefaultEpubRuntimeRoots(fileManager: FileManager = .default) throws {
        guard let defaultDocumentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw FixtureToolError.usage(
                "Fixture process could not resolve its default Documents directory."
            )
        }
        let expectedDocumentsURL = documentsURL.resolvingSymlinksInPath().standardizedFileURL
        let actualDocumentsURL = defaultDocumentsURL.resolvingSymlinksInPath().standardizedFileURL
        guard actualDocumentsURL.path == expectedDocumentsURL.path else {
            throw FixtureToolError.usage(
                "Fixture process Documents root mismatch; expected '\(expectedDocumentsURL.path)', "
                    + "resolved '\(actualDocumentsURL.path)'."
            )
        }

        let expectedSwordURL = expectedDocumentsURL
            .appendingPathComponent("sword", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let actualSwordURL = URL(
            fileURLWithPath: SwordManager.defaultModulePath(),
            isDirectory: true
        )
        .resolvingSymlinksInPath()
        .standardizedFileURL
        guard actualSwordURL.path == expectedSwordURL.path else {
            throw FixtureToolError.usage(
                "Fixture process SWORD root mismatch; expected '\(expectedSwordURL.path)', "
                    + "resolved '\(actualSwordURL.path)'."
            )
        }
    }
}

/// Main command runner for reset and seed operations.
private struct FixtureTool {
    let arguments: ToolArguments

    /**
     Executes the parsed fixture command.
     *
     * - Throws: `FixtureToolError` or filesystem/SwiftData errors emitted by the selected command.
     */
    func run() throws {
        switch arguments.command {
        case .reset:
            try resetContainer()
        case .seed:
            guard let scenario = arguments.scenario else {
                throw FixtureToolError.usage("Seed command requires a scenario.")
            }
            try seedScenario(scenario)
        }
    }

    /**
     Deletes the app's persisted SwiftData stores, search index, and SWORD install metadata.
     *
     * - Throws: Path-validation or filesystem errors before any reset mutation can target a
     *   process-default library outside the requested simulator container.
     */
    private func resetContainer() throws {
        let paths = FixturePaths(dataContainerURL: arguments.dataContainerURL)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: paths.applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.documentsURL, withIntermediateDirectories: true)
        try paths.validateDefaultEpubRuntimeRoots(fileManager: fileManager)

        try removeSQLiteFamily(at: paths.cloudStoreURL)
        try removeSQLiteFamily(at: paths.localStoreURL)
        try removeSQLiteFamily(at: paths.applicationSupportURL.appendingPathComponent("CloudStore.store"))
        try removeSQLiteFamily(at: paths.documentsURL.appendingPathComponent("search_indexes.sqlite"))
        let installManagerURL = paths.documentsURL.appendingPathComponent("sword_install", isDirectory: true)
        if fileManager.fileExists(atPath: installManagerURL.path) {
            try fileManager.removeItem(at: installManagerURL)
        }
        try removeUITestSwordModules(from: paths)
        try removeUITestEpub()
    }

    /**
     Opens the simulator store files and writes one deterministic fixture scenario.
     *
     * - Parameter scenario: Named scenario describing the persisted graph to seed.
     * - Returns: Base64 property-list preferences for the app to apply on first launch.
     * - Throws: SwiftData or validation errors when the store graph cannot be prepared.
     */
    private func seedScenario(_ scenario: FixtureScenario) throws {
        let paths = FixturePaths(dataContainerURL: arguments.dataContainerURL)
        let context = try FixtureContext(
            paths: paths,
            bundleIdentifier: arguments.bundleIdentifier,
            swordFixtureURL: arguments.swordFixtureURL
        )
        let encodedPreferences = try context.seed(scenario)
        print(encodedPreferences)
    }

    /**
     Removes one SQLite store file together with its `-wal` and `-shm` sidecars.
     *
     * - Parameter fileURL: Canonical SQLite store file path.
     * - Throws: Filesystem deletion errors for existing files.
     */
    private func removeSQLiteFamily(at fileURL: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm", ".backup"] {
            let candidateURL = URL(fileURLWithPath: fileURL.path + suffix)
            if fileManager.fileExists(atPath: candidateURL.path) {
                try fileManager.removeItem(at: candidateURL)
            }
        }
    }

    /**
     Removes deterministic SWORD modules written by UI-test scenarios.

     Baseline fixture resets intentionally leave the seeded KJV fixture module in place, but
     scenario-local modules must not leak into later grouped test runs that use the same simulator.
     This includes modules installed through the real Downloads workflow, not only modules seeded
     directly by the fixture writer.
     */
    private func removeUITestSwordModules(from paths: FixturePaths) throws {
        let fileManager = FileManager.default
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let candidates = [
            swordURL.appendingPathComponent("mods.d/modules-conf.cache", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/000uitestcomm.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/uitestcomm.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/aatestweb.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/uitestweb.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/uitestdlrec.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/uitestdlwarn.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/uitestlocked.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/000uitestlocka.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/001uitestlockb.conf", isDirectory: false),
            swordURL.appendingPathComponent("mods.d/aatestreadable.conf", isDirectory: false),
            swordURL.appendingPathComponent("modules/comments/rawcom/000uitestcomm", isDirectory: true),
            swordURL.appendingPathComponent("modules/comments/rawcom/uitestcomm", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/aatestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/aatestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/uitestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestdlrec", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/uitestdlwarn", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestlocked", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestlocka", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestlockb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/aatestreadable", isDirectory: true),
        ] + (0..<59).map { index in
            swordURL.appendingPathComponent(
                String(format: "mods.d/uitestquick%02d.conf", index),
                isDirectory: false
            )
        }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    /** Removes only the deterministic EPUB identity owned by the local quick-menu scenario. */
    private func removeUITestEpub() throws {
        let sourceURL = URL(fileURLWithPath: "UITESTEPUB.epub", isDirectory: false)
        let identifier = EpubReader.installCandidate(forEpubURL: sourceURL).identifier
        try EpubReader.delete(identifier: identifier)
    }
}

/// Mutable SwiftData-backed fixture writer bound to one simulator container.
private final class FixtureContext {
    private let paths: FixturePaths
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let workspaceStore: WorkspaceStore
    private let settingsStore: SettingsStore
    private let bookmarkStore: BookmarkStore
    private let bookmarkService: BookmarkService
    private let remoteSyncSettingsStore: RemoteSyncSettingsStore
    private let fileManager = FileManager.default
    private let explicitSwordFixtureURL: URL?
    private var swordManager: SwordManager?

    /**
     Creates the store-backed fixture writer for one simulator container.
     *
     * - Parameters:
     *   - paths: Resolved simulator data-container paths.
     *   - bundleIdentifier: App bundle identifier used for remote-sync device folder naming.
     * - Throws: SwiftData initialization errors when the container cannot be opened.
     */
    init(paths: FixturePaths, bundleIdentifier: String, swordFixtureURL: URL? = nil) throws {
        self.paths = paths
        self.explicitSwordFixtureURL = swordFixtureURL?.standardizedFileURL
        try fileManager.createDirectory(at: paths.applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.documentsURL, withIntermediateDirectories: true)

        let cloudModels = BibleCoreBaseModelRegistration.cloudModels
        let localModels = BibleCoreBaseModelRegistration.localModels

        let schema = Schema(cloudModels + localModels)
        let cloudConfiguration = ModelConfiguration(
            "AndBible",
            schema: Schema(cloudModels),
            url: paths.cloudStoreURL,
            cloudKitDatabase: .none
        )
        let localConfiguration = ModelConfiguration(
            "LocalStore",
            schema: Schema(localModels),
            url: paths.localStoreURL,
            cloudKitDatabase: .none
        )

        self.modelContainer = try ModelContainer(
            for: schema,
            configurations: [cloudConfiguration, localConfiguration]
        )
        self.modelContext = ModelContext(modelContainer)
        self.workspaceStore = WorkspaceStore(modelContext: modelContext)
        self.settingsStore = SettingsStore(modelContext: modelContext)
        self.bookmarkStore = BookmarkStore(modelContext: modelContext)
        self.bookmarkService = BookmarkService(store: bookmarkStore)
        self.remoteSyncSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        _ = bundleIdentifier
    }

    /**
     Writes one named deterministic scenario into the opened simulator stores.
     *
     * - Parameter scenario: Scenario to write.
     * - Returns: Base64 property-list preferences for the app's first launch in the test session.
     * - Throws: Validation errors when the baseline workspace graph cannot be created.
     */
    func seed(_ scenario: FixtureScenario) throws -> String {
        let baseline = try ensureBaseline()

        switch scenario {
        case .baseline:
            break
        case .performanceBookmarks10:
            try seedPerformanceBookmarks(count: 10)
            try seedKJVFixtureSearchIndex()
        case .performanceBookmarks1000:
            try seedPerformanceBookmarks(count: 1_000)
            try seedKJVFixtureSearchIndex()
        case .performanceBookmarks10000:
            try seedPerformanceBookmarks(count: 10_000)
            try seedKJVFixtureSearchIndex()
        case .baselineThreeWindows:
            try ensureVisibleBibleWindowCount(3, baseline: baseline)
        case .commentaryModule:
            try seedUITestCommentaryModule()
        case .commentaryModuleThreeWindows:
            try ensureVisibleBibleWindowCount(3, baseline: baseline)
            try seedUITestCommentaryModule()
        case .searchIndexed:
            try seedKJVFixtureSearchIndex()
        case .searchCompletePreview:
            try seedKJVFixtureSearchIndex(includesCompletePreview: true)
        case .searchCompletePreviewMulti:
            try seedUITestBibleModule()
            try seedMultiTranslationSearchIndex(includesCompletePreview: true)
        case .searchMultiTranslation:
            try seedUITestBibleModule()
            try seedMultiTranslationSearchIndex()
        case .documentSwitchCustomTheme:
            try seedUITestBibleModule()
            seedCustomColorSettings()
            seedScopedThemeColorSettings(baseline: baseline)
            seedReaderSystemDayMode()
        case .documentSwitchCustomNightTheme:
            try seedUITestBibleModule()
            seedCustomColorSettings()
            seedScopedThemeColorSettings(baseline: baseline)
            seedReaderNightMode()
        case .bookmarkNavigation:
            try seedBookmarkNavigation()
        case .bookmarkNavigationThreeWindows:
            try ensureVisibleBibleWindowCount(3, baseline: baseline)
            try seedBookmarkNavigation()
        case .bookmarkMultiRow:
            try seedBookmarkMultiRow()
        case .bookmarkFilter:
            try seedBookmarkFilter()
            seedHistorySingle(window: baseline.window)
        case .bookmarkRowLabel:
            try seedBookmarkRowLabel()
        case .bookmarkGenericVisible:
            seedBookmarkGenericVisible()
        case .bookmarkStudyPad:
            try seedBookmarkStudyPad()
        case .historyMultiRow:
            seedHistoryMultiRow(window: baseline.window)
        case .myNotesSingle:
            try seedMyNotesSingle()
        case .myDocumentsSingle:
            try seedMyDocumentsSingle()
        case .localQuickDocuments:
            try seedMyDocumentsSingle()
            try seedUITestCommentaryModule()
            try seedLocalQuickMenuEpub()
        case .longBibleQuickSelector:
            try seedLongBibleQuickSelector()
        case .syncNextCloud:
            seedSyncNextCloud(enabledCategories: [])
        case .syncNextCloudBookmarksEnabled:
            seedSyncNextCloud(enabledCategories: [.bookmarks])
        case .displayColorsCustom:
            seedCustomColorSettings()
        case .readerNightMode:
            seedReaderNightMode()
        case .downloadsRowOrder:
            try seedDownloadsRowOrderCatalog()
        case .lockedPickerDownloads:
            try seedLockedPickerDownloads()
        case .lockedReadableNext:
            try seedLockedReadableNext(baseline: baseline)
        case .lockedSuggestedCommentary:
            try seedLockedSuggestedCommentary(baseline: baseline)
        case .lockedStartupQueue:
            try seedLockedStartupQueue(baseline: baseline)
        }

        try modelContext.save()
        return try encodedPreferences(["icloud_sync_enabled": false])
    }

    /// Disk shape used by `ModuleRepository.loadCachedCatalogs()` for one UI-test catalog fixture.
    private struct CachedDownloadCatalogFixture: Codable {
        /// Fresh cache timestamp so Downloads opens cached rows without automatic repository refresh.
        var timestamp: Date

        /// Remote modules exposed by the deterministic smoke-test source.
        var modules: [CachedDownloadModuleFixture]
    }

    /// Disk shape used by `ModuleRepository.loadCachedCatalogs()` for one module row.
    private struct CachedDownloadModuleFixture: Codable {
        /// Module initials used as the Downloads row identity.
        var name: String

        /// Android-visible abbreviation, or `nil` to preserve the initials fallback.
        var abbreviation: String?

        /// Human-readable description shown under the initials.
        var description: String

        /// Android/SWORD category string consumed by `ModuleCategory`.
        var category: String

        /// Module language code shown by the Downloads language filter.
        var language: String

        /// Repository source name matching the cache filename and config row.
        var sourceName: String

        /// SWORD driver used for row category inference and install-file planning.
        var modDrv: String

        /// SWORD `DataPath` preserved for install attempts from the cached row.
        var dataPath: String

        /// Full `.conf` payload persisted if an install succeeds.
        var confContent: String

        /// Remote module version used for update-vs-installed status comparison.
        var version: String

        /// Raw SWORD catalog size field used by row metadata display.
        var size: String

        /// Android repository family, normally `sword-https` for this fixture.
        var repositoryType: String?

        /// Optional direct MyBible package URL; absent for SWORD rows.
        var downloadURL: String?

        /// Optional MyBible package filename; absent for SWORD rows.
        var packageFileName: String?
    }

    /**
     Seeds a deterministic Downloads catalog for abbreviation and install-lifecycle contracts.

     Android updates the tapped document row in place when a download starts; it does not rebuild and
     status-sort the list until filter data is rebuilt. This fixture writes a single local-only source
     and fresh cache containing installed KJV, the original recommended/warning transfer rows, and an
     equal-rank pair whose initials order opposes its abbreviation order. One UI contract verifies the
     pair's visible abbreviation, search match, and ordering. The install lifecycle contract separately
     cancels and completes the original warning row while checking its order during the transfer and
     after relaunch. The seeded source uses the exact synthetic HTTPS host intercepted by the test's
     injected repository transport. The macOS fixture service owns the corresponding package bytes and
     transfer gate; production repository download, extraction, publication, and cancellation code
     remains authoritative.
     */
    private func seedDownloadsRowOrderCatalog() throws {
        let sourceName = "UITest Downloads"
        let installManagerURL = paths.documentsURL.appendingPathComponent("sword_install", isDirectory: true)
        if fileManager.fileExists(atPath: installManagerURL.path) {
            try fileManager.removeItem(at: installManagerURL)
        }

        let cacheURL = installManagerURL.appendingPathComponent("catalog-cache", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let config = """
        [General]
        PassiveFTP=true

        [Sources]
        # AndBibleDefaultSourcesVersion=2
        HTTPSource=\(sourceName)|uitest-download.invalid|/catalog
        """
        try config.write(
            to: installManagerURL.appendingPathComponent("InstallMgr.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let catalog = CachedDownloadCatalogFixture(
            timestamp: Date(),
            modules: [
                cachedDownloadModule(
                    name: "KJV",
                    description: "King James Version",
                    dataPath: "./modules/texts/ztext/kjv/",
                    modDrv: "zText",
                    version: "3.1",
                    sourceName: sourceName
                ),
                cachedDownloadModule(
                    name: "ZZZREMOTE",
                    abbreviation: "Aardvark",
                    description: "First opposing remote identity",
                    dataPath: "./modules/texts/rawtext/zzzremote/",
                    modDrv: "RawText",
                    version: "1.0",
                    sourceName: sourceName
                ),
                cachedDownloadModule(
                    name: "AAAREMOTE",
                    abbreviation: "Aaron",
                    description: "Second opposing remote identity",
                    dataPath: "./modules/texts/rawtext/aaaremote/",
                    modDrv: "RawText",
                    version: "1.0",
                    sourceName: sourceName
                ),
                cachedDownloadModule(
                    name: "UITESTDLREC",
                    description: "UI Test Downloads Recommended",
                    dataPath: "./modules/texts/rawtext/uitestdlrec/",
                    modDrv: "RawText",
                    version: "1.0",
                    sourceName: sourceName
                ),
                cachedDownloadModule(
                    name: "UITESTDLWARN",
                    description: "UI Test Downloads Warning",
                    dataPath: "./modules/texts/ztext/uitestdlwarn/",
                    modDrv: "zText",
                    version: "1.0",
                    sourceName: sourceName
                ),
            ]
        )
        let data = try JSONEncoder().encode(catalog)
        try data.write(
            to: cacheURL.appendingPathComponent("\(sourceName).json", isDirectory: false),
            options: .atomic
        )
    }

    /**
     Builds one cached Bible row using the same persisted shape as `ModuleRepository`.

     - Parameters:
       - name: Module initials shown in the Downloads list.
       - abbreviation: Optional Android-visible title distinct from the installation identity.
       - description: User-visible module description.
       - dataPath: SWORD `DataPath` used if the row is installed during the smoke test.
       - modDrv: SWORD driver used for category and install-file planning.
       - version: Remote module version string.
       - sourceName: Repository source name matching the cache filename and config row.
     - Returns: Codable fixture row consumed by `ModuleRepository.loadCachedCatalogs()`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func cachedDownloadModule(
        name: String,
        abbreviation: String? = nil,
        description: String,
        dataPath: String,
        modDrv: String,
        version: String,
        sourceName: String
    ) -> CachedDownloadModuleFixture {
        let normalizedDataPath = dataPath.hasPrefix("./") ? dataPath : "./\(dataPath)"
        let abbreviationLine = abbreviation.map { "Abbreviation=\($0)\n" } ?? ""
        let confContent = """
        [\(name)]
        Description=\(description)
        \(abbreviationLine)DataPath=\(normalizedDataPath)
        ModDrv=\(modDrv)
        Category=Biblical Texts
        Encoding=UTF-8
        Lang=en
        Version=\(version)
        """
        return CachedDownloadModuleFixture(
            name: name,
            abbreviation: abbreviation,
            description: description,
            category: ModuleCategory.bible.rawValue,
            language: "en",
            sourceName: sourceName,
            modDrv: modDrv,
            dataPath: normalizedDataPath,
            confContent: confContent,
            version: version,
            size: "1000",
            repositoryType: SourceConfig.swordHTTPSRepositoryType,
            downloadURL: nil,
            packageFileName: nil
        )
    }

    /**
     Seeds one real encrypted RawText Bible plus a matching Downloads catalog row.

     The payload is generated once by `SwordManagerTestSapphire` and checked into test resources.
     This fixture only copies those opaque bytes and writes scenario-specific SWORD configuration;
     it contains no cipher implementation and never substitutes plaintext beneath locked metadata.
     KJV's index is also seeded so the dedicated locked-row Search test never creates it at runtime.
     */
    private func seedLockedPickerDownloads() throws {
        try seedKJVFixtureSearchIndex()
        try installEncryptedRawTextModule(
            name: "UITESTLOCKED",
            description: "Synthetic Encrypted UI Test Bible",
            abbreviation: "Locked Test Bible",
            configFileName: "uitestlocked.conf",
            dataDirectoryName: "uitestlocked"
        )
        let sourceName = "UITest Locked"
        let installManagerURL = paths.documentsURL.appendingPathComponent("sword_install", isDirectory: true)
        let cacheURL = installManagerURL.appendingPathComponent("catalog-cache", isDirectory: true)
        try fileManager.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        let config = """
        [General]
        PassiveFTP=true

        [Sources]
        # AndBibleDefaultSourcesVersion=2
        HTTPSource=\(sourceName)|uitest-locked.invalid|/catalog
        """
        try config.write(
            to: installManagerURL.appendingPathComponent("InstallMgr.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let module = cachedDownloadModule(
            name: "UITESTLOCKED",
            abbreviation: "Locked Test Bible",
            description: "Synthetic Encrypted UI Test Bible",
            dataPath: "./modules/texts/rawtext/uitestlocked/",
            modDrv: "RawText",
            version: "1.0",
            sourceName: sourceName
        )
        let data = try JSONEncoder().encode(
            CachedDownloadCatalogFixture(timestamp: Date(), modules: [module])
        )
        try data.write(
            to: cacheURL.appendingPathComponent("\(sourceName).json", isDirectory: false),
            options: .atomic
        )
    }

    /**
     Seeds the isolated readable-next inventory without changing the validated picker fixture.

     KJV and `AATESTREADABLE` are readable; `UITESTLOCKED` remains retained but inaccessible. The
     swap-activity Bible tap must cycle through only the two readable identities.

     - Parameter baseline: Active pane whose retained Bible identity is set to the locked module.
     - Side effects: Writes the locked picker fixture, one cloned readable Bible, retained target,
       and toolbar action preference.
     - Failure modes: Propagates fixture, module-copy, index, and persistence errors.
     */
    private func seedLockedReadableNext(baseline: BaselineState) throws {
        try seedLockedPickerDownloads()
        try seedUITestReadableBibleModule()
        baseline.pageManager.bibleDocument = "UITESTLOCKED"
        settingsStore.setString(.toolbarButtonActions, value: "swap-activity")
    }

    /**
     Seeds the isolated commentary-to-retained-locked-Bible suggestion inventory.

     The startup controller may publish readable KJV, but the pane retains `UITESTLOCKED`; after a
     real commentary switch, the next Bible action must preserve that exact locked suggestion.

     - Parameter baseline: Active pane whose retained Bible identity is set to the locked module.
     - Side effects: Writes the locked picker fixture, one commentary, retained target, and toolbar
       action preference.
     - Failure modes: Propagates fixture, commentary, index, and persistence errors.
     */
    private func seedLockedSuggestedCommentary(baseline: BaselineState) throws {
        try seedLockedPickerDownloads()
        try seedUITestCommentaryModule()
        baseline.pageManager.bibleDocument = "UITESTLOCKED"
        settingsStore.setString(.toolbarButtonActions, value: "swap-activity")
    }

    /**
     Installs the second readable Bible used to prove swap-activity next-document ordering.

     The module clones the checked-in KJV zText payload under distinct static metadata. This keeps
     the fixture to three declared Bible identities (`KJV`, `AATESTREADABLE`, `UITESTLOCKED`) while
     exercising normal SWORD discovery and rendering instead of a fixture-only backend.

     - Side effects: Copies KJV fixture bytes into the simulator SWORD root, writes one module
       configuration, and invalidates the SWORD module-discovery cache.
     - Failure modes: Propagates missing fixture and filesystem errors; no partial success is
       reported to the UI test host.
     */
    private func seedUITestReadableBibleModule() throws {
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = swordURL.appendingPathComponent(
            "modules/texts/ztext/aatestreadable",
            isDirectory: true
        )
        let sourceDataURL = try swordFixtureResourceURL()
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("kjv", isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try copyDirectoryContents(from: sourceDataURL, to: dataURL, replacingExisting: true)
        let conf = """
        [AATESTREADABLE]
        Description=UI Test Readable Bible
        DataPath=./modules/texts/ztext/aatestreadable/
        ModDrv=zText
        SourceType=OSIS
        Encoding=UTF-8
        CompressType=ZIP
        BlockType=BOOK
        Lang=en
        Versification=KJV
        About=Deterministic readable Bible for iOS next-document UI automation.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("aatestreadable.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try removeCachedSwordModuleConfig(in: modsDURL)
    }

    /**
     Installs 59 readable Bible aliases over the one checked-in KJV payload.

     Together with KJV, this produces the 60-row inventory used to exercise the real quick-menu
     viewport. Each alias has its own native registration but reuses the immutable fixture bytes,
     avoiding dozens of multi-megabyte test-only payload copies.

     - Side effects: Writes 59 scenario-owned configuration files and invalidates SWORD discovery.
     - Failure modes: Propagates fixture and configuration write errors.
     */
    private func seedLongBibleQuickSelector() throws {
        _ = try ensureKJVSwordFixtureModuleAvailable()
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try removeCachedSwordModuleConfig(in: modsDURL)

        for index in 0..<59 {
            let initials = String(format: "UITESTQ%02d", index)
            let configuration = """
            [\(initials)]
            Description=UI Test Quick Bible \(index)
            Abbreviation=\(initials)
            DataPath=./modules/texts/ztext/kjv/
            ModDrv=zText
            SourceType=OSIS
            Encoding=UTF-8
            CompressType=ZIP
            BlockType=BOOK
            Lang=en
            Versification=KJV
            About=Readable alias for the long Bible quick-selector UI journey.
            """
            try configuration.write(
                to: modsDURL.appendingPathComponent(
                    String(format: "uitestquick%02d.conf", index),
                    isDirectory: false
                ),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /**
     Seeds two locked-only real encrypted Bibles in deterministic initial queue order.

     Baseline persistence is created first so the app has a valid workspace graph. KJV is then
     removed from the installed SWORD inventory and the page retains the first locked identity;
     startup must process both initial locked rows before performing one fresh reconciliation.
     */
    private func seedLockedStartupQueue(baseline: BaselineState) throws {
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let kjvConfig = modsDURL.appendingPathComponent("kjv.conf", isDirectory: false)
        let kjvData = swordURL.appendingPathComponent("modules/texts/ztext/kjv", isDirectory: true)
        for item in [kjvConfig, kjvData] where fileManager.fileExists(atPath: item.path) {
            try fileManager.removeItem(at: item)
        }
        try installEncryptedRawTextModule(
            name: "UITESTLOCKA",
            description: "First Synthetic Locked Bible",
            abbreviation: "A Locked Bible",
            configFileName: "000uitestlocka.conf",
            dataDirectoryName: "uitestlocka"
        )
        try installEncryptedRawTextModule(
            name: "UITESTLOCKB",
            description: "Second Synthetic Locked Bible",
            abbreviation: "B Locked Bible",
            configFileName: "001uitestlockb.conf",
            dataDirectoryName: "uitestlockb"
        )
        baseline.pageManager.bibleDocument = "UITESTLOCKA"
        baseline.pageManager.bibleVersification = "KJV"
        try removeCachedSwordModuleConfig(in: modsDURL)
    }

    /** Copies the four hash-verified Sapphire payload files and writes one locked module config. */
    private func installEncryptedRawTextModule(
        name: String,
        description: String,
        abbreviation: String,
        configFileName: String,
        dataDirectoryName: String
    ) throws {
        let sourceURL = try encryptedRawTextFixtureResourceURL()
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let destinationURL = swordURL.appendingPathComponent(
            "modules/texts/rawtext/\(dataDirectoryName)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try copyDirectoryContents(from: sourceURL, to: destinationURL, replacingExisting: true)
        let conf = """
        [\(name)]
        Description=\(description)
        Abbreviation=\(abbreviation)
        DataPath=./modules/texts/rawtext/\(dataDirectoryName)/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        CipherKey=
        About=Real encrypted UI fixture metadata for \(name).
        UnlockInfo=
        """
        try conf.write(
            to: modsDURL.appendingPathComponent(configFileName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try removeCachedSwordModuleConfig(in: modsDURL)
    }

    /** Resolves and validates the exact four opaque encrypted RawText resource files. */
    private func encryptedRawTextFixtureResourceURL() throws -> URL {
        let resourceURL = try swordFixtureResourceURL().appendingPathComponent(
            "ui-test-encrypted-rawtext",
            isDirectory: true
        )
        let required = ["ot", "ot.vss", "nt", "nt.vss"]
        let names = Set(
            try fileManager.contentsOfDirectory(atPath: resourceURL.path)
        )
        guard names == Set(required) else {
            throw FixtureToolError.missingSwordFixtureResources(resourceURL.path)
        }
        for name in required {
            let fileURL = resourceURL.appendingPathComponent(name, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw FixtureToolError.missingSwordFixtureResources(fileURL.path)
            }
        }
        return resourceURL
    }

    /** One canonical FTS row written by deterministic Search UI fixtures. */
    private struct SeededSearchRow {
        /// Source-style verse key retained for compatibility presentation.
        let verseKey: String

        /// Visible text analyzed through the production module-language pipeline.
        let plainText: String

        /// Exact installed source initials owning this row.
        let moduleName: String

        /// Locale-independent canonical book identity.
        let osisBookId: String

        /// Source-style SWORD display name retained for native module results.
        let displayBook: String

        /// One-based chapter coordinate.
        let chapter: Int

        /// One-based verse coordinate.
        let verse: Int
    }

    /** Exact installed generation and analyzer language recorded by one seeded module. */
    private struct SeededSearchModuleMetadata {
        /// Production fingerprint/version identity derived from the installed SWORD module.
        let identity: SearchIndexSourceIdentity

        /// Module language selecting the production analyzer profile.
        let languageCode: String
    }

    /** One lexical row plus the visible words its encoded UTF-16 ranges must select. */
    private struct SeededStrongRow {
        /// Canonical verse key shared with the corresponding seeded FTS row.
        let verseKey: String

        /// Canonical Strong's token persisted in the lexical facet.
        let token: String

        /// Exact installed module identity owning the FTS and lexical rows.
        let moduleName: String

        /// Stable source order used when multiple lexical rows share one verse.
        let entryOrder: Int

        /// Production `start:length` range encoding over the FTS row's UTF-16 preview.
        let highlightRanges: String

        /// Visible words every encoded range must extract in order.
        let expectedHighlightedText: [String]
    }

    /**
     Seeds a minimal KJV fixture FTS index so Search UI tests start from a ready state.
     *
     * The seeded rows are intentionally narrow: they cover the current Search UI assertions for
     * fixture queries (`earth`, `earth void`, `jesus`, and `noah`) without forcing UI tests to
     * wait for runtime index creation on fresh simulators.
     *
     * - Parameter includesCompletePreview: Adds the long Genesis 3:17 row only for the dedicated
     *   complete-preview scenario, leaving established performance fixtures unchanged.
     * - Throws: `FixtureToolError.sqlite` when the search-index database cannot be created or
     *   written.
     */
    private func seedKJVFixtureSearchIndex(includesCompletePreview: Bool = false) throws {
        let databaseURL = paths.documentsURL.appendingPathComponent("search_indexes.sqlite")
        let sourceMetadata = try seededSearchSourceMetadata(for: "KJV")
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else {
            throw FixtureToolError.sqlite(
                "Unable to open search index database at '\(databaseURL.path)'."
            )
        }
        defer { sqlite3_close(db) }

        try prepareSearchIndexSchema(in: db)
        try executeSearchSQL("DELETE FROM verse_fts WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("DELETE FROM verse_strongs WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("DELETE FROM indexed_modules WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("BEGIN TRANSACTION", db: db)

        do {
            let rows = Self.seededSearchRows
                + (includesCompletePreview ? [Self.completePreviewSearchRow] : [])
            try insertSeededSearchRows(rows, into: db)
            try insertSeededStrongRows(into: db)
            try recordSeededSearchModule(
                sourceMetadata,
                into: db,
                verseCount: Int32(rows.count)
            )
            try executeSearchSQL("COMMIT", db: db)
        } catch {
            _ = try? executeSearchSQL("ROLLBACK", db: db)
            throw error
        }
    }

    /**
     Seeds a second deterministic Bible module plus grouped FTS rows for multi-translation search.
     *
     * The fixture writes deterministic KJV rows plus two `AATESTWEB` rows for the same query so a
     * grouped search must report results from more than one selected translation.
     *
     * - Parameter includesCompletePreview: Adds the same complete KJV passage to both translations
     *   only for the dedicated expanded-preview scenario.
     * - Throws: `FixtureToolError.sqlite` when the search-index database cannot be created or
     *   written.
     */
    private func seedMultiTranslationSearchIndex(includesCompletePreview: Bool = false) throws {
        let databaseURL = paths.documentsURL.appendingPathComponent("search_indexes.sqlite")
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else {
            throw FixtureToolError.sqlite(
                "Unable to open search index database at '\(databaseURL.path)'."
            )
        }
        defer { sqlite3_close(db) }

        try prepareSearchIndexSchema(in: db)
        let sourceMetadataByModule = try Dictionary(
            uniqueKeysWithValues: ["KJV", "AATESTWEB"].map {
                let metadata = try seededSearchSourceMetadata(for: $0)
                return ($0, metadata)
            }
        )
        for moduleName in ["KJV", "AATESTWEB", "UITESTWEB"] {
            try executeSearchSQL("DELETE FROM verse_fts WHERE module_name = '\(moduleName)'", db: db)
            try executeSearchSQL("DELETE FROM verse_strongs WHERE module_name = '\(moduleName)'", db: db)
            try executeSearchSQL("DELETE FROM indexed_modules WHERE module_name = '\(moduleName)'", db: db)
        }
        try executeSearchSQL("BEGIN TRANSACTION", db: db)

        do {
            let completePreviewRows = includesCompletePreview ? [
                Self.completePreviewSearchRow,
                SeededSearchRow(
                    verseKey: "Genesis 3:17",
                    plainText: Self.completePreviewSearchRow.plainText,
                    moduleName: "AATESTWEB",
                    osisBookId: "Gen",
                    displayBook: "Genesis",
                    chapter: 3,
                    verse: 17
                ),
            ] : []
            let rows = Self.seededSearchRows + Self.seededMultiTranslationSearchRows
                + completePreviewRows
            try insertSeededSearchRows(rows, into: db)
            try insertSeededStrongRows(into: db)
            for moduleName in Set(rows.map { $0.moduleName }).sorted() {
                let verseCount = rows.filter { $0.moduleName == moduleName }.count
                guard let sourceMetadata = sourceMetadataByModule[moduleName] else {
                    throw FixtureToolError.missingSwordModule(moduleName)
                }
                try recordSeededSearchModule(
                    sourceMetadata,
                    into: db,
                    verseCount: Int32(verseCount)
                )
            }
            try executeSearchSQL("COMMIT", db: db)
        } catch {
            _ = try? executeSearchSQL("ROLLBACK", db: db)
            throw error
        }
    }

    /**
     Inserts the supplied deterministic FTS rows used by Search UI fixtures.
     *
     * - Parameters:
     *   - rows: FTS rows to write.
     *   - db: Open SQLite handle for `search_indexes.sqlite`.
     * - Throws: `FixtureToolError.sqlite` when row insertion fails.
     */
    private func insertSeededSearchRows(
        _ rows: [SeededSearchRow],
        into db: OpaquePointer
    ) throws {
        let analyzer = SearchTextAnalyzer.profile(for: "en")
        let sql = """
            INSERT INTO verse_fts (
                search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                display_book, display_book_mode, chapter, verse, book_order, canon_scope
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(
                from: db,
                fallback: "Unable to prepare seeded search row insert statement."
            )
        }
        defer { sqlite3_finalize(statement) }

        for (entryOrder, row) in rows.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let searchText = try SearchTextAnalyzer.analyzedText(row.plainText, profile: analyzer)
            sqlite3_bind_text(statement, 1, searchText, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.verseKey, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.plainText, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, row.moduleName, -1, sqliteTransient)
            sqlite3_bind_int(statement, 5, Int32(entryOrder))
            sqlite3_bind_text(statement, 6, row.osisBookId, -1, sqliteTransient)
            sqlite3_bind_text(statement, 7, row.displayBook, -1, sqliteTransient)
            sqlite3_bind_text(statement, 8, SearchBookNamePresentation.source.rawValue, -1, sqliteTransient)
            sqlite3_bind_int(statement, 9, Int32(row.chapter))
            sqlite3_bind_int(statement, 10, Int32(row.verse))
            sqlite3_bind_int64(
                statement,
                11,
                sqlite3_int64(SearchCanonicalBookCatalog.order(of: row.osisBookId))
            )
            sqlite3_bind_text(
                statement,
                12,
                SearchCanonicalBookCatalog.section(of: row.osisBookId).rawValue,
                -1,
                sqliteTransient
            )
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(
                    from: db,
                    fallback: "Unable to insert seeded search row '\(row.verseKey)'."
                )
            }
        }
    }

    /**
     Inserts deterministic Strong's-token rows paired with the seeded KJV FTS rows.

     The Search UI treats ordinary text search and Strong's lookup as separate index facets, just
     like Android's JSword/Lucene index has distinct text and `strong` fields. The fixture must
     therefore seed lexical-token rows for Strong's UI tests instead of marking a text-only index as
     Strong's-ready.

     - Parameter db: Open SQLite handle for `search_indexes.sqlite`.
     - Throws: `FixtureToolError.sqlite` when row insertion fails.
     */
    private func insertSeededStrongRows(into db: OpaquePointer) throws {
        let sql = """
            INSERT OR IGNORE INTO verse_strongs (
                module_name, token, verse_key, entry_order, highlight_ranges
            ) VALUES (?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(
                from: db,
                fallback: "Unable to prepare seeded Strong's row insert statement."
            )
        }
        defer { sqlite3_finalize(statement) }

        for row in Self.seededStrongRows {
            try validateSeededStrongRow(row)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.moduleName, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.token, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.verseKey, -1, sqliteTransient)
            sqlite3_bind_int(statement, 4, Int32(row.entryOrder))
            sqlite3_bind_text(statement, 5, row.highlightRanges, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(
                    from: db,
                    fallback: "Unable to insert seeded Strong's row '\(row.verseKey)'."
                )
            }
        }
    }

    /**
     Validates one lexical fixture row against the exact visible FTS preview it references.

     - Parameter row: Strong's row whose comma-separated `start:length` pairs must be checked.
     - Returns: Nothing after every range extracts the declared visible word in order.
     - Side effects: Reads only the immutable seeded fixture arrays.
     - Throws: `FixtureToolError.sqlite` when the paired FTS row is missing, a range is malformed or
       out of UTF-16 bounds, or the encoded range selects a different word.
     */
    private func validateSeededStrongRow(_ row: SeededStrongRow) throws {
        let searchRows = Self.seededSearchRows + Self.seededMultiTranslationSearchRows
        guard let source = searchRows.first(where: {
            $0.moduleName == row.moduleName && $0.verseKey == row.verseKey
        }) else {
            throw FixtureToolError.sqlite(
                "Seeded Strong's row '\(row.moduleName):\(row.verseKey)' has no visible FTS row."
            )
        }

        let sourceUnits = Array(source.plainText.utf16)
        let extracted = try row.highlightRanges.split(separator: ",").map { encoded -> String in
            let components = encoded.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let location = Int(components[0]),
                  let length = Int(components[1]),
                  location >= 0,
                  length > 0,
                  location <= sourceUnits.count,
                  length <= sourceUnits.count - location else {
                throw FixtureToolError.sqlite(
                    "Invalid seeded Strong's highlight range '\(encoded)' for '\(row.verseKey)'."
                )
            }
            return String(decoding: sourceUnits[location..<(location + length)], as: UTF16.self)
        }
        guard extracted == row.expectedHighlightedText else {
            throw FixtureToolError.sqlite(
                "Seeded Strong's ranges for '\(row.verseKey)' selected \(extracted), "
                    + "expected \(row.expectedHighlightedText)."
            )
        }
    }

    /**
     Records the seeded module metadata expected by `SearchIndexService.hasIndex`.

     The schema version comes from production `SearchIndexService` so fixture-generated search
     databases remain valid when the app intentionally invalidates older index formats.
     *
     * - Parameters:
     *   - sourceMetadata: Exact installed module generation and analyzer language.
     *   - db: Open SQLite handle for `search_indexes.sqlite`.
     *   - verseCount: Number of seeded verse rows for the module.
     * - Throws: `FixtureToolError.sqlite` when the metadata row cannot be written.
     */
    private func recordSeededSearchModule(
        _ sourceMetadata: SeededSearchModuleMetadata,
        into db: OpaquePointer,
        verseCount: Int32
    ) throws {
        let identity = sourceMetadata.identity
        let analyzerIdentifier = SearchTextAnalyzer.profile(
            for: sourceMetadata.languageCode
        ).identifier
        let sql = """
            INSERT OR REPLACE INTO indexed_modules (
                module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                strongs_complete, source_version, source_fingerprint, store_generation
            ) VALUES (?, ?, datetime('now'), ?, ?, ?, 1, ?, ?, 0)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(
                from: db,
                fallback: "Unable to prepare indexed_modules insert statement."
            )
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, identity.moduleName, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, verseCount)
        sqlite3_bind_int(statement, 3, Int32(SearchIndexService.currentSchemaVersion))
        sqlite3_bind_text(statement, 4, sourceMetadata.languageCode, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, analyzerIdentifier, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, identity.version, -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, identity.fingerprint, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(
                from: db,
                fallback: "Unable to record seeded search module metadata."
            )
        }
    }

    /**
     Creates the Search FTS tables used by production `SearchIndexService`.
     *
     * - Parameter db: Open SQLite handle for `search_indexes.sqlite`.
     * - Throws: `FixtureToolError.sqlite` when schema setup fails.
     */
    private func prepareSearchIndexSchema(in db: OpaquePointer) throws {
        try executeSearchSQL("PRAGMA journal_mode=WAL", db: db)
        try executeSearchSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                search_text,
                verse_key UNINDEXED,
                plain_text UNINDEXED,
                module_name UNINDEXED,
                entry_order UNINDEXED,
                osis_book UNINDEXED,
                display_book UNINDEXED,
                display_book_mode UNINDEXED,
                chapter UNINDEXED,
                verse UNINDEXED,
                book_order UNINDEXED,
                canon_scope UNINDEXED,
                tokenize='ascii'
            )
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS verse_strongs (
                module_name TEXT NOT NULL,
                token TEXT NOT NULL,
                verse_key TEXT NOT NULL,
                entry_order INTEGER NOT NULL,
                highlight_ranges TEXT NOT NULL,
                PRIMARY KEY (module_name, token, verse_key)
            )
        """, db: db)
        try executeSearchSQL("""
            CREATE INDEX IF NOT EXISTS idx_verse_strongs_module_token
            ON verse_strongs (module_name, token, entry_order)
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS search_index_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                store_generation INTEGER NOT NULL
            )
        """, db: db)
        try executeSearchSQL("""
            INSERT OR IGNORE INTO search_index_state (id, store_generation) VALUES (1, 0)
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER NOT NULL,
                indexed_at TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                language_code TEXT NOT NULL,
                analyzer_id TEXT NOT NULL,
                strongs_complete INTEGER NOT NULL DEFAULT 0,
                source_version TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                store_generation INTEGER NOT NULL
            )
        """, db: db)
    }

    /** Resolves exact production readiness metadata for one installed fixture module. */
    private func seededSearchSourceMetadata(
        for moduleName: String
    ) throws -> SeededSearchModuleMetadata {
        let swordURL = try ensureKJVSwordFixtureModuleAvailable()
        guard let manager = SwordManager(modulePath: swordURL.path),
              let module = manager.module(named: moduleName) else {
            throw FixtureToolError.missingSwordModule(moduleName)
        }
        return SeededSearchModuleMetadata(
            identity: module.searchIndexSourceIdentity,
            languageCode: module.info.language
        )
    }

    /**
     Executes one SQLite statement against the seeded search database.
     *
     * - Parameters:
     *   - sql: SQL statement to execute.
     *   - db: Open SQLite handle.
     * - Throws: `FixtureToolError.sqlite` when SQLite returns a non-success code.
     */
    private func executeSearchSQL(_ sql: String, db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(from: db, fallback: "SQLite execution failed for statement: \(sql)")
        }
    }

    /**
     Converts the current SQLite error into a `FixtureToolError.sqlite`.
     *
     * - Parameters:
     *   - db: Open SQLite handle whose error state should be read.
     *   - fallback: Fallback message when SQLite exposes no error text.
     * - Returns: Structured fixture-tool error describing the SQLite failure.
     */
    private func sqliteError(from db: OpaquePointer, fallback: String) -> FixtureToolError {
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? fallback
        return .sqlite(message)
    }

    /**
     SQLite row set preseeded into the KJV fixture search index.
     */
    private static let seededSearchRows: [SeededSearchRow] = [
        SeededSearchRow(
            verseKey: "Genesis 1:2",
            plainText: "And the earth was without form, and void; and darkness was upon the face "
                + "of the deep. And the Spirit of God moved upon the face of the waters.",
            moduleName: "KJV",
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: 2
        ),
        SeededSearchRow(
            verseKey: "Genesis 6:8",
            plainText: "But Noah found grace in the eyes of the LORD.",
            moduleName: "KJV",
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 6,
            verse: 8
        ),
        SeededSearchRow(
            verseKey: "Matthew 1:1",
            plainText: "The book of the generation of Jesus Christ, the son of David, the son of Abraham.",
            moduleName: "KJV",
            osisBookId: "Matt",
            displayBook: "Matthew",
            chapter: 1,
            verse: 1
        ),
    ]

    /**
     Complete KJV Genesis 3:17 preview used only by the visible Search-row contract.

     Its final phrase extends beyond both former 200- and 240-character preview caps. The separate
     scenario preserves the established performance fixture and existing Search query result sets.
     Ingestion parity is tested with real source modules in the package lane; this fixture supplies
     the independently specified indexed input to the production Search form and row renderer.
     */
    private static let completePreviewSearchRow = SeededSearchRow(
        verseKey: "Genesis 3:17",
        plainText: "And unto Adam he said, Because thou hast hearkened unto the voice of thy wife, "
            + "and hast eaten of the tree, of which I commanded thee, saying, Thou shalt not eat "
            + "of it: cursed is the ground for thy sake; in sorrow shalt thou eat of it all the "
            + "days of thy life;",
        moduleName: "KJV",
        osisBookId: "Gen",
        displayBook: "Genesis",
        chapter: 3,
        verse: 17
    )

    /**
     SQLite rows preseeded into the KJV fixture Strong's index facet.

     The token and its UTF-16 `God` range are attached to the full deterministic `Genesis 1:2`
     preview in `seededSearchRows`. Fixture insertion validates that the encoded range still selects
     `God`, preventing schema-ready test data from silently emphasizing an unrelated substring.
     */
    private static let seededStrongRows: [SeededStrongRow] = [
        SeededStrongRow(
            verseKey: "Genesis 1:2",
            token: "H0430",
            moduleName: "KJV",
            entryOrder: 0,
            highlightRanges: "104:3",
            expectedHighlightedText: ["God"]
        ),
    ]

    /**
     Additional deterministic rows used only by the grouped multi-translation Search fixture.
     */
    private static let seededMultiTranslationSearchRows: [SeededSearchRow] = [
        SeededSearchRow(
            verseKey: "Genesis 1:2",
            plainText: "The earth had become formless and empty, and darkness was on the surface of the deep.",
            moduleName: "AATESTWEB",
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: 2
        ),
        SeededSearchRow(
            verseKey: "John 3:16",
            plainText: "For God so loved the earth that the deterministic fixture can prove grouped search totals.",
            moduleName: "AATESTWEB",
            osisBookId: "John",
            displayBook: "John",
            chapter: 3,
            verse: 16
        ),
    ]

    /// SQLite destructor token instructing SQLite to copy bound text values.
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /**
     Seeds a real SWORD Bible module used by multi-translation Search UI tests.

     Search assertions read deterministic FTS rows from `search_indexes.sqlite`, but production
     module discovery and book-list generation now require normal SWORD zText semantics. The fixture
     therefore clones the KJV test fixture data under deterministic `AATESTWEB` metadata instead of
     publishing an empty RawText shell that Android/JSword-style discovery would reject.
     */
    private func seedUITestBibleModule() throws {
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = swordURL.appendingPathComponent(
            "modules/texts/ztext/aatestweb",
            isDirectory: true
        )
        let sourceDataURL = try swordFixtureResourceURL()
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("kjv", isDirectory: true)

        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try removeCachedSwordModuleConfig(in: modsDURL)
        try copyDirectoryContents(from: sourceDataURL, to: dataURL, replacingExisting: true)

        let conf = """
        [AATESTWEB]
        Description=UI Test Web Bible
        DataPath=./modules/texts/ztext/aatestweb/
        ModDrv=zText
        SourceType=OSIS
        Encoding=UTF-8
        CompressType=ZIP
        BlockType=BOOK
        Lang=en
        Versification=KJV
        About=Deterministic Bible module for iOS multi-translation Search UI automation.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("aatestweb.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Seeds a minimal SWORD commentary module used by document-switching UI tests.

     Tests that exercise commentary switching need a deterministic installed commentary row without
     redistributing another real module.
     */
    private func seedUITestCommentaryModule() throws {
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = swordURL.appendingPathComponent(
            "modules/comments/rawcom/000uitestcomm",
            isDirectory: true
        )
        try fileManager.createDirectory(at: modsDURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try removeCachedSwordModuleConfig(in: modsDURL)

        let conf = """
        [000UITestComm]
        Description=UI Test Commentary
        DataPath=./modules/comments/rawcom/000uitestcomm/
        ModDrv=RawCom
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        About=Deterministic empty commentary module for iOS UI automation.
        """
        try conf.write(
            to: modsDURL.appendingPathComponent("000uitestcomm.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        for fileName in ["ot", "ot.vss", "nt", "nt.vss"] {
            let url = dataURL.appendingPathComponent(fileName, isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
        }
    }

    /// Removes SWORD's module cache so newly seeded UI-test modules are discovered on app launch.
    private func removeCachedSwordModuleConfig(in modsDURL: URL) throws {
        let cacheURL = modsDURL.appendingPathComponent("modules-conf.cache", isDirectory: false)
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
    }

    /**
     Resolves the explicit artifact SWORD fixture or the local repository test fixture directory.

     Product-reuse callers supply the artifact path explicitly. That path is authoritative and a
     missing directory fails without falling through to the producer checkout compiled into
     `#filePath`. Local source runs retain repository discovery without requiring the app target to
     package KJV.

     - Returns: Repository `Sources/BibleUI/Tests/BibleUITests/Fixtures/sword` directory.
     - Throws: `FixtureToolError.missingSwordFixtureResources` when the resources are unavailable.
     */
    private func swordFixtureResourceURL() throws -> URL {
        if let explicitSwordFixtureURL {
            let requiredConfiguration = explicitSwordFixtureURL
                .appendingPathComponent("mods.d", isDirectory: true)
                .appendingPathComponent("kjv.conf", isDirectory: false)
            guard fileManager.fileExists(atPath: requiredConfiguration.path) else {
                throw FixtureToolError.missingSwordFixtureResources(explicitSwordFixtureURL.path)
            }
            return explicitSwordFixtureURL
        }

        var candidateRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidateRootURL.path != candidateRootURL.deletingLastPathComponent().path {
            let fixtureSwordURL = candidateRootURL
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("BibleUI", isDirectory: true)
                .appendingPathComponent("Tests", isDirectory: true)
                .appendingPathComponent("BibleUITests", isDirectory: true)
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("sword", isDirectory: true)
            if fileManager.fileExists(atPath: fixtureSwordURL.path) {
                return fixtureSwordURL
            }
            candidateRootURL.deleteLastPathComponent()
        }

        let fallbackPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("BibleUI", isDirectory: true)
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("BibleUITests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
            .path
        throw FixtureToolError.missingSwordFixtureResources(fallbackPath)
    }

    /**
     Ensures the simulator SWORD directory contains the KJV test fixture module.

     UI fixture commands seed reader state before the app launches. Bookmark fixtures need KJV
     available immediately so their persisted ordinals are produced by SWORD instead of by a static
     approximation.

     - Returns: Simulator document `sword` directory.
     - Throws: Filesystem errors or `FixtureToolError.missingSwordFixtureResources`.
     */
    @discardableResult
    private func ensureKJVSwordFixtureModuleAvailable() throws -> URL {
        let sourceSwordURL = try swordFixtureResourceURL()
        let destinationSwordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let sourceConfURL = sourceSwordURL
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("kjv.conf", isDirectory: false)
        let destinationModsDURL = destinationSwordURL.appendingPathComponent("mods.d", isDirectory: true)
        let destinationConfURL = destinationModsDURL.appendingPathComponent("kjv.conf", isDirectory: false)
        let sourceDataURL = sourceSwordURL
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("kjv", isDirectory: true)
        let destinationDataURL = destinationSwordURL
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("kjv", isDirectory: true)

        try fileManager.createDirectory(at: destinationModsDURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: destinationConfURL.path) {
            try fileManager.copyItem(at: sourceConfURL, to: destinationConfURL)
        }
        try copyDirectoryContents(from: sourceDataURL, to: destinationDataURL, replacingExisting: false)
        try removeCachedSwordModuleConfig(in: destinationModsDURL)
        return destinationSwordURL
    }

    /**
     Recursively copies directory contents for deterministic SWORD fixture modules.

     - Parameters:
       - source: Source directory to copy.
       - destination: Destination directory to create or update.
       - replacingExisting: Whether an existing destination tree should be removed first.
     - Throws: Filesystem errors when copying fails.
     */
    private func copyDirectoryContents(from source: URL, to destination: URL, replacingExisting: Bool) throws {
        if replacingExisting, fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            let target = destination.appendingPathComponent(
                item.lastPathComponent,
                isDirectory: values.isDirectory == true
            )

            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target, replacingExisting: replacingExisting)
            } else if replacingExisting || !fileManager.fileExists(atPath: target.path) {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    /**
     Ensures the app has a valid active workspace, window, and Bible page-manager state.
     *
     * - Returns: Baseline workspace graph suitable for further fixture mutation.
     * - Throws: `FixtureToolError` when the baseline graph cannot be created.
     */
    private func ensureBaseline() throws -> BaselineState {
        try ensureKJVSwordFixtureModuleAvailable()
        bookmarkService.ensureSystemLabels()

        let workspace: Workspace
        if let activeID = settingsStore.activeWorkspaceId,
           let persistedWorkspace = workspaceStore.workspace(id: activeID) {
            workspace = persistedWorkspace
        } else if let firstWorkspace = workspaceStore.workspaces().first {
            workspace = firstWorkspace
            settingsStore.activeWorkspaceId = firstWorkspace.id
        } else {
            workspace = workspaceStore.createWorkspace(name: "Default")
            settingsStore.activeWorkspaceId = workspace.id
        }

        let window: Window
        if let existingWindow = workspaceStore.windows(workspaceId: workspace.id).first {
            window = existingWindow
        } else {
            window = workspaceStore.addWindow(to: workspace, document: "KJV", category: "bible")
        }

        let pageManager: PageManager
        if let existingPageManager = window.pageManager {
            pageManager = existingPageManager
        } else {
            let createdPageManager = PageManager(id: window.id, currentCategoryName: "bible")
            createdPageManager.window = window
            modelContext.insert(createdPageManager)
            pageManager = createdPageManager
        }

        pageManager.currentCategoryName = "bible"
        pageManager.bibleDocument = pageManager.bibleDocument ?? "KJV"
        pageManager.bibleVersification = pageManager.bibleVersification ?? "KJVA"
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1

        try modelContext.save()

        return BaselineState(workspace: workspace, window: window, pageManager: pageManager)
    }

    /**
     Ensures a fixture workspace starts with the requested number of visible Bible panes.

     Third-pane UI tests validate pane-local behavior after the app has already entered
     multi-window mode. Android no longer exposes the add-window footer button in that mode, so
     those tests seed the workspace shape directly instead of requiring an iOS-only repeated add
     affordance.

     - Parameters:
       - count: Number of visible Bible windows the fixture should expose.
       - baseline: Baseline workspace graph returned by `ensureBaseline()`.
     - Side effects: Inserts missing windows, assigns unique sequential order numbers to every
       persisted workspace window, normalizes the requested visible windows to KJV Genesis 1,
       minimizes extra windows, and saves the SwiftData context.
     - Failure modes: Rethrows SwiftData save failures.
     */
    private func ensureVisibleBibleWindowCount(_ count: Int, baseline: BaselineState) throws {
        guard count > 0 else { return }

        var windows = workspaceStore.windows(workspaceId: baseline.workspace.id)
        while windows.count < count {
            let window = workspaceStore.addWindow(
                to: baseline.workspace,
                document: baseline.pageManager.bibleDocument ?? "KJV",
                category: "bible"
            )
            windows.append(window)
        }

        windows = windows.sorted {
            if $0.orderNumber != $1.orderNumber {
                return $0.orderNumber < $1.orderNumber
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        for (order, window) in windows.enumerated() {
            window.orderNumber = order
            guard order < count else {
                window.layoutState = "minimized"
                continue
            }

            window.layoutState = "split"
            window.isLinksWindow = false
            window.layoutWeight = 1.0

            let pageManager: PageManager
            if let existingPageManager = window.pageManager {
                pageManager = existingPageManager
            } else {
                let createdPageManager = PageManager(id: window.id, currentCategoryName: "bible")
                createdPageManager.window = window
                modelContext.insert(createdPageManager)
                pageManager = createdPageManager
            }

            pageManager.currentCategoryName = "bible"
            pageManager.bibleDocument = pageManager.bibleDocument ?? baseline.pageManager.bibleDocument ?? "KJV"
            pageManager.bibleVersification = pageManager.bibleVersification ?? "KJVA"
            pageManager.bibleBibleBook = 0
            pageManager.bibleChapterNo = 1
            pageManager.bibleVerseNo = 1
        }

        try modelContext.save()
    }

    /**
     Seeds one bookmark that should navigate from Genesis 1 to Exodus 2.
     */
    private func seedBookmarkNavigation() throws {
        _ = try createBibleBookmark(
            bookName: "Exodus",
            chapter: 2,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
    }

    /**
     Seeds a controlled bookmark-size axis for Release navigation measurements.

     Exactly ten bookmarks belong to the visible Genesis 1 chapter. Remaining rows are distributed
     over Exodus chapters 1–40, keeping the visible chapter's required annotation work constant.
     Every fifth row has a fixed-size note. UUIDs, dates, references, and note contents are stable.
     This isolates bookmark growth; it is not a claim to model every shape of user library.

     - Parameter count: Total bookmark count, at least ten, in a newly reset fixture container.
     - Side effects: Inserts verified bookmark and note rows into the fixture's production-shaped
       stores. The outer seed operation saves them once; this does not time production mutation APIs.
     - Failure modes: Nonempty bookmark fixtures, invalid counts, or an unresolved authoritative
       source range fail fixture preparation rather than producing a smaller dataset.
     */
    private func seedPerformanceBookmarks(count: Int) throws {
        guard count >= 10,
              try modelContext.fetchCount(FetchDescriptor<BibleBookmark>()) == 0 else {
            throw FixtureToolError.usage("Performance bookmarks require an empty store and at least ten rows")
        }
        let previousAutosave = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previousAutosave }

        var references: [(book: String, range: VerifiedKJVAOrdinalRange)] = []
        for referenceIndex in 0...40 {
            let book = referenceIndex == 0 ? "Genesis" : "Exodus"
            let chapter = max(referenceIndex, 1)
            let ordinal = try resolveKJVOrdinal(bookName: book, chapter: chapter, verse: 1)
            guard let range = VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: ordinal,
                sourceOrdinalEnd: ordinal
            ) else {
                throw FixtureToolError.unresolvedVerse("\(book).\(chapter).1")
            }
            references.append((book, range))
        }

        for index in 0..<count {
            let reference = references[index < 10 ? 0 : 1 + (index - 10) % 40]
            guard let id = UUID(uuidString: "F0000000-0000-4000-8000-\(String(format: "%012d", index))") else {
                throw FixtureToolError.usage("Cannot construct performance bookmark identity")
            }
            let date = seededDate(offset: index)
            let range = reference.range
            let bookmark = BibleBookmark(
                id: id,
                kjvOrdinalStart: range.kjvaOrdinalStart,
                kjvOrdinalEnd: range.kjvaOrdinalEnd,
                ordinalStart: range.sourceOrdinalStart,
                ordinalEnd: range.sourceOrdinalEnd,
                v11n: range.sourceVersification,
                bookInitials: range.sourceBookInitials,
                createdAt: date,
                lastUpdatedOn: date,
                ordinalTrustMetadata: range.ordinalTrust
            )
            bookmark.book = reference.book
            modelContext.insert(bookmark)
            if index.isMultiple(of: 5) {
                let note = BibleBookmarkNotes(
                    bookmarkId: id,
                    notes: String(repeating: "Deterministic performance annotation. ", count: 8),
                    contentType: "MARKDOWN"
                )
                modelContext.insert(note)
                bookmark.notes = note
            }
        }
        guard try modelContext.fetchCount(FetchDescriptor<BibleBookmark>()) == count,
              try modelContext.fetchCount(FetchDescriptor<BibleBookmarkNotes>()) == (count + 4) / 5 else {
            throw FixtureToolError.usage("Performance fixture did not produce the requested row counts")
        }
    }

    /**
     Seeds two bookmark rows used by delete and sort workflows.
     */
    private func seedBookmarkMultiRow() throws {
        _ = try createBibleBookmark(
            bookName: "Matthew",
            chapter: 3,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
        _ = try createBibleBookmark(
            bookName: "Exodus",
            chapter: 2,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 10)
        )
    }

    /**
     Seeds two labeled bookmark rows plus a StudyPad entry used by bookmark route workflows.
     */
    private func seedBookmarkFilter() throws {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        let secondaryLabel = ensureUserLabel(name: "Other Label", color: 0xFFFFCC99)
        _ = try createBibleBookmark(
            bookName: "Exodus",
            chapter: 2,
            label: secondaryLabel,
            note: nil,
            createdAt: seededDate(offset: 10)
        )
        _ = try createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            label: uiTestLabel,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
        if bookmarkService.studyPadEntries(labelId: uiTestLabel.id).isEmpty,
           let (entry, _, _, _) = bookmarkService.createStudyPadEntry(labelId: uiTestLabel.id, afterOrderNumber: -1) {
            bookmarkService.updateStudyPadTextEntryText(id: entry.id, text: "")
        }
    }

    /**
     Seeds one bookmark assigned to the primary UI-test label.
     */
    private func seedBookmarkRowLabel() throws {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        _ = try createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            label: uiTestLabel,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
    }

    /**
     Seeds one generic bookmark and one initially-unassigned label for visible workflow coverage.
     */
    private func seedBookmarkGenericVisible() {
        _ = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        let bookmark = bookmarkService.addGenericBookmark(
            bookInitials: "UITESTDICT",
            key: "Entry 1",
            startOrdinal: 7,
            endOrdinal: 7
        )
        bookmark.createdAt = seededDate(offset: 20)
        bookmark.lastUpdatedOn = seededDate(offset: 20)
        bookmarkStore.saveChanges()
    }

    /**
     Seeds one label-backed bookmark and an initial empty StudyPad entry.
     */
    private func seedBookmarkStudyPad() throws {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        _ = try createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            label: uiTestLabel,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
        if bookmarkService.studyPadEntries(labelId: uiTestLabel.id).isEmpty,
           let (entry, _, _, _) = bookmarkService.createStudyPadEntry(labelId: uiTestLabel.id, afterOrderNumber: -1) {
            bookmarkService.updateStudyPadTextEntryText(id: entry.id, text: "")
        }
    }

    /**
     Seeds one history row that should navigate from Genesis 1 to Exodus 2.
     *
     * - Parameter window: Active window that should own the seeded history row.
     */
    private func seedHistorySingle(window: Window) {
        let item = HistoryItem(
            createdAt: seededDate(offset: 20),
            document: "KJV",
            key: "Exod.2.1"
        )
        item.window = window
        modelContext.insert(item)
    }

    /**
     Seeds two history rows ordered newest-first for multirow delete workflows.
     *
     * - Parameter window: Active window that should own the seeded history rows.
     */
    private func seedHistoryMultiRow(window: Window) {
        let matthew = HistoryItem(
            createdAt: seededDate(offset: 10),
            document: "KJV",
            key: "Matt.3.1"
        )
        matthew.window = window
        modelContext.insert(matthew)

        let exodus = HistoryItem(
            createdAt: seededDate(offset: 20),
            document: "KJV",
            key: "Exod.2.1"
        )
        exodus.window = window
        modelContext.insert(exodus)
    }

    /**
     Seeds one Genesis 1 bookmark note for the My Notes flow.
     */
    private func seedMyNotesSingle() throws {
        let bookmark = try createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Creation begins with God.")
    }

    /**
     Seeds one My Document with a single Markdown page for drawer routing coverage.
     *
     * Android's drawer opens `MyDocumentsActivity`, then a page selector. The seeded graph uses the
     * same SwiftData model and stable initials/page key as synced or user-created documents so UI
     * tests can prove row selection reaches the reader's My Documents page loader.
     *
     * - Throws: `FixtureToolError.usage` if the deterministic UUID literals are malformed.
     */
    private func seedMyDocumentsSingle() throws {
        guard let documentId = UUID(uuidString: "44444444-4444-4444-4444-444444444444"),
              let pageId = UUID(uuidString: "55555555-5555-5555-5555-555555555555") else {
            throw FixtureToolError.usage("Invalid deterministic My Documents fixture UUID.")
        }

        let createdAt = seededDate(offset: 20)
        let document = MyDocument(
            id: documentId,
            name: "UI Test Document",
            documentDescription: "Seeded My Documents entry",
            initials: "UITESTDOC",
            orderNumber: 0,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            orderNumber: 0,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let content = MyDocumentPageContent(
            pageId: pageId,
            content: "# UI Test My Document\n\nMy Document page one."
        )

        page.pageContent = content
        page.document = document
        document.pages = [page]
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
    }

    /** Installs one real EPUB generation into the simulator app's production library root. */
    private func seedLocalQuickMenuEpub() throws {
        try paths.validateDefaultEpubRuntimeRoots(fileManager: fileManager)
        let temporaryRoot = paths.dataContainerURL.appendingPathComponent(
            "tmp/ui-test-local-quick-documents",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let archiveURL = temporaryRoot.appendingPathComponent("UITESTEPUB.epub", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let entries: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>UI Test EPUB</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="first" href="text/first.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="first"/></spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol>
                <li><a href="text/first.xhtml#start">First</a></li>
              </ol></nav></body>
            </html>
            """),
            ("OPS/text/first.xhtml", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <section id="start"><p>EPUB page one.</p></section>
            </body></html>
            """),
        ]
        let archive = try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: Data($0.1.utf8))
        })
        try archive.write(to: archiveURL, options: .atomic)
        let candidate = EpubReader.installCandidate(forEpubURL: archiveURL)
        guard candidate.initials == "Epub-UITESTEPUB_epub" else {
            throw FixtureToolError.usage("Unexpected deterministic EPUB initials: \(candidate.initials)")
        }
        let installedIdentifier = try EpubReader.install(
            epubURL: archiveURL,
            moduleStoreRootURL: paths.documentsURL.appendingPathComponent("sword", isDirectory: true),
            admittingCandidateWith: { _ in }
        )
        guard installedIdentifier == candidate.identifier else {
            throw FixtureToolError.usage("EPUB fixture published an unexpected stable identifier.")
        }
    }

    /**
     Seeds remote-sync settings for the NextCloud backend.
     *
     * - Parameter enabledCategories: Categories that should start enabled.
     */
    private func seedSyncNextCloud(enabledCategories: [RemoteSyncCategory]) {
        remoteSyncSettingsStore.selectedBackend = .nextCloud
        for category in RemoteSyncCategory.allCases {
            remoteSyncSettingsStore.setSyncEnabled(enabledCategories.contains(category), for: category)
        }
    }

    /**
     Seeds one non-default color tuple into the global text-display defaults.
     */
    private func seedCustomColorSettings() {
        var settings = settingsStore.globalTextDisplaySettings()
        settings.dayTextColor = Int(Int32(bitPattern: 0xFF112233))
        settings.dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        settings.dayNoise = 7
        settings.nightTextColor = Int(Int32(bitPattern: 0xFFF1E7D0))
        settings.nightBackground = Int(Int32(bitPattern: 0xFF101820))
        settings.nightNoise = 5
        settingsStore.setGlobalTextDisplaySettings(settings)
    }

    /**
     Seeds distinct workspace and window theme overrides above the custom global palette.

     The three scopes intentionally use visibly different day and night backgrounds. Document-switch
     recordings can therefore identify a transient loss of the window override as a workspace,
     global, or application-default fallback instead of merely asserting the final Boolean mode.

     - Parameter baseline: Canonical fixture graph whose active workspace/window receive overrides.
     - Side effects:
       - stores green/blue theme colors on the active workspace
       - stores lavender/purple theme colors on the active window page manager
     - Failure modes: none; the baseline contract always supplies both owning models.
     */
    private func seedScopedThemeColorSettings(baseline: BaselineState) {
        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.dayTextColor = Int(Int32(bitPattern: 0xFF173528))
        workspaceSettings.dayBackground = Int(Int32(bitPattern: 0xFFE0F0E8))
        workspaceSettings.dayNoise = 0
        workspaceSettings.nightTextColor = Int(Int32(bitPattern: 0xFFE0EDF8))
        workspaceSettings.nightBackground = Int(Int32(bitPattern: 0xFF1B2735))
        workspaceSettings.nightNoise = 0
        baseline.workspace.textDisplaySettings = workspaceSettings

        var windowSettings = TextDisplaySettings()
        windowSettings.dayTextColor = Int(Int32(bitPattern: 0xFF213547))
        windowSettings.dayBackground = Int(Int32(bitPattern: 0xFFDDE7FA))
        windowSettings.dayNoise = 0
        windowSettings.nightTextColor = Int(Int32(bitPattern: 0xFFF0E7FA))
        windowSettings.nightBackground = Int(Int32(bitPattern: 0xFF2B183C))
        windowSettings.nightNoise = 0
        baseline.pageManager.textDisplaySettings = windowSettings
    }

    /**
     Seeds Android's manual night-mode policy with its toggle enabled.

     Reader UI tests use this scenario to prove night rendering from the persisted Android-equivalent
     settings rather than relying on the host simulator's system appearance.

     - Side effects:
     - stores `manual` for `night_mode_pref3`
     - enables the persisted `night_mode` toggle
     */
    private func seedReaderNightMode() {
        settingsStore.setString(.nightModePref3, value: NightModeSetting.manual.rawValue)
        settingsStore.setBool("night_mode", value: true)
    }

    /**
     Seeds Android's System night-mode policy while the simulator is in day appearance.

     Passage-chooser regressions must exercise System mode explicitly: Manual mode ignores the
     environment scheme and would conceal a pushed destination leaking a dark preference into the
     reader window.

     - Side effects:
       - stores `system` for `night_mode_pref3`
       - clears the persisted manual `night_mode` toggle
     - Failure modes: none; `SettingsStore` applies registry-backed values synchronously.
     */
    private func seedReaderSystemDayMode() {
        settingsStore.setString(.nightModePref3, value: NightModeSetting.system.rawValue)
        settingsStore.setBool("night_mode", value: false)
    }

    /**
     Resolves one KJV verse ordinal through SWORD versification metadata.

     Bookmark and My Notes fixtures must store SWORD/JSword-style ordinals, including intro slots.
     Arithmetic ordinals are invalid under the current reader contract and break chapter-range
     lookups as soon as production code asks SWORD for real verse positions. The host fixture
     executable runs on macOS, so it derives the ordinal from SWORD's book order and chapter verse
     counts using JSword's introduction-slot model instead of trusting platform-local
     `VerseKey.getIndex()` behavior.

     - Parameters:
       - bookName: Human-readable SWORD book name such as `Genesis` or `Matthew`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Native SWORD verse-key ordinal.
     - Throws: `FixtureToolError` when the KJV test fixture module or verse cannot be resolved.
     */
    private func resolveKJVOrdinal(bookName: String, chapter: Int, verse: Int) throws -> Int {
        let module = try kjvSwordModule()
        let osisBookId = try resolveOsisBookId(bookName: bookName, chapter: chapter, module: module)
        return try resolveIntroInclusiveOrdinal(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            module: module
        )
    }

    /**
     Loads the KJV test fixture module from the simulator SWORD directory.

     The returned module borrows handles owned by `SwordManager`, so the manager is cached for the
     lifetime of the fixture context.

     - Returns: Loaded KJV SWORD module.
     - Throws: `FixtureToolError.missingSwordModule` if SWORD cannot load KJV.
     */
    private func kjvSwordModule() throws -> SwordModule {
        let swordURL = try ensureKJVSwordFixtureModuleAvailable()
        let manager: SwordManager
        if let existingManager = swordManager {
            manager = existingManager
        } else if let createdManager = SwordManager(modulePath: swordURL.path) {
            swordManager = createdManager
            manager = createdManager
        } else {
            throw FixtureToolError.missingSwordModule("KJV")
        }

        guard let module = manager.module(named: "KJV") else {
            throw FixtureToolError.missingSwordModule("KJV")
        }
        return module
    }

    /**
     Resolves a human-readable book name to the active SWORD OSIS identifier.

     The primary path uses SWORD's discovered book list. The parser fallback still delegates to SWORD
     and covers alternate names or abbreviations without adding a parallel iOS-only book table.

     - Parameters:
       - bookName: Human-readable book name to resolve.
       - chapter: Chapter used when asking SWORD's parser for a concrete key fallback.
       - module: Loaded SWORD module.
     - Returns: OSIS book identifier, such as `Gen`, `Exod`, or `Matt`.
     - Throws: `FixtureToolError.unresolvedVerse` when SWORD cannot resolve the book.
     */
    private func resolveOsisBookId(bookName: String, chapter: Int, module: SwordModule) throws -> String {
        let normalizedBookName = bookName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let book = module.getBookList().first(where: { book in
            book.name.lowercased() == normalizedBookName ||
            book.abbreviation.lowercased() == normalizedBookName ||
            book.osisId.lowercased() == normalizedBookName
        }) {
            return book.osisId
        }

        let parsedKeys = module.parseKeyList("\(bookName) \(chapter):1")
        if let firstKey = parsedKeys.first,
           let osisBookId = firstKey.split(separator: ".").first,
           !osisBookId.isEmpty {
            return String(osisBookId)
        }

        throw FixtureToolError.unresolvedVerse("\(bookName) \(chapter):1")
    }

    /**
     Computes JSword/SWORD-style ordinals from real SWORD book and chapter metadata.

     JSword ordinals include the Bible introduction, testament introductions, one book introduction
     per book, and one chapter introduction per real chapter. This mirrors the iOS reader contract
     protected by `testKJVFixtureVerseOrdinalsUseIntroInclusiveVersification` while avoiding the
     previous fixture-only `chapter * 40` approximation.

     - Parameters:
       - osisBookId: OSIS book identifier resolved by SWORD.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
       - module: Loaded SWORD module supplying book order and chapter lengths.
     - Returns: Intro-inclusive ordinal for the requested verse.
     - Throws: `FixtureToolError.unresolvedVerse` when the reference is outside the module.
     */
    private func resolveIntroInclusiveOrdinal(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        module: SwordModule
    ) throws -> Int {
        var ordinal = 0
        var currentTestament: Int?

        for book in module.getBookList() {
            if currentTestament != book.testament {
                ordinal += 1
                currentTestament = book.testament
            }

            ordinal += 1
            guard book.chapterCount > 0 else { continue }

            for candidateChapter in 1...book.chapterCount {
                ordinal += 1

                guard let verseCount = module.verseCount(
                    osisBookId: book.osisId,
                    chapter: candidateChapter
                ) else {
                    throw FixtureToolError.unresolvedVerse("\(book.osisId).\(candidateChapter).1")
                }

                if book.osisId == osisBookId && candidateChapter == chapter {
                    guard (1...verseCount).contains(verse) else {
                        throw FixtureToolError.unresolvedVerse("\(osisBookId).\(chapter).\(verse)")
                    }
                    return ordinal + verse
                }

                ordinal += verseCount
            }
        }

        throw FixtureToolError.unresolvedVerse("\(osisBookId).\(chapter).\(verse)")
    }

    /**
     Creates one deterministic Bible bookmark with optional label and note state.
     *
     * - Parameters:
     *   - bookName: Human-readable book name surfaced by the bookmark list.
     *   - chapter: One-based chapter number. The fixture stores the first verse in that chapter.
     *   - label: Optional user label that should be assigned as the primary label.
     *   - note: Optional bookmark note.
     *   - createdAt: Deterministic creation date used to control list ordering.
     * - Returns: The persisted bookmark.
     * - Throws: `FixtureToolError` when SWORD cannot resolve the requested verse.
     */
    @discardableResult
    private func createBibleBookmark(
        bookName: String,
        chapter: Int,
        label: Label?,
        note: String?,
        createdAt: Date
    ) throws -> BibleBookmark {
        let ordinalStart = try resolveKJVOrdinal(bookName: bookName, chapter: chapter, verse: 1)
        guard let ordinalRange = VerifiedKJVAOrdinalRange(
            resolvingSourceBookInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalStart: ordinalStart,
            sourceOrdinalEnd: ordinalStart
        ) else {
            throw FixtureToolError.unresolvedVerse("\(bookName).\(chapter).1")
        }
        let bookmark = bookmarkService.addBibleBookmark(
            ordinalRange: ordinalRange
        )
        bookmark.book = bookName
        bookmark.createdAt = createdAt
        bookmark.lastUpdatedOn = createdAt
        if let label {
            _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
            bookmarkService.setPrimaryLabel(bookmarkId: bookmark.id, labelId: label.id)
        }
        if let note {
            bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: note)
        }
        bookmarkStore.saveChanges()
        return bookmark
    }

    /**
     Overload that lazily resolves a named label before creating the bookmark.
     */
    @discardableResult
    private func createBibleBookmark(
        bookName: String,
        chapter: Int,
        labelName: String?,
        note: String?,
        createdAt: Date
    ) throws -> BibleBookmark {
        let label = labelName.map { ensureUserLabel(name: $0, color: Label.defaultColor) }
        return try createBibleBookmark(
            bookName: bookName,
            chapter: chapter,
            label: label,
            note: note,
            createdAt: createdAt
        )
    }

    /**
     Creates or reuses one user-visible label by name.
     *
     * - Parameters:
     *   - name: User-visible label name.
     *   - color: Signed ARGB color used for list chips and StudyPad handoff surfaces.
     * - Returns: Persisted label matching the requested name.
     */
    private func ensureUserLabel(name: String, color: Int) -> Label {
        if let existing = bookmarkService.allLabels().first(where: { $0.name == name }) {
            return existing
        }
        return bookmarkService.createLabel(name: name, color: color)
    }

    /**
     Encodes a minimal preferences plist for the app to apply through `UserDefaults` on launch.
     *
     * - Parameter values: Dictionary encoded into the launch-environment payload.
     * - Returns: Base64 representation of the binary property list.
     * - Throws: Property-list serialization errors.
     */
    private func encodedPreferences(_ values: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        return data.base64EncodedString()
    }

    /**
     Builds deterministic timestamps used to control list ordering.
     *
     * - Parameter offset: Minutes added to the fixed base date.
     * - Returns: Stable timestamp for persisted fixture rows.
     */
    private func seededDate(offset minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes * 60))
    }
}

/// One resolved active workspace graph used as the fixture baseline.
private struct BaselineState {
    let workspace: Workspace
    let window: Window
    let pageManager: PageManager
}

/// In-memory secret store used so the fixture tool never touches the host Keychain.
private final class InMemorySecretStore: SecretStoring {
    private var values: [String: String] = [:]

    func secret(forKey key: String) -> String? {
        values[key]
    }

    func setSecret(_ value: String, forKey key: String) {
        values[key] = value
    }

    func removeSecret(forKey key: String) {
        values.removeValue(forKey: key)
    }
}
