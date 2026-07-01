import Foundation
import SQLite3
import SwiftData
import BibleCore
import SwordKit

/**
 Host-side fixture writer for XCUITests.

 The tool operates directly on the simulator app data container instead of relying on production
 launch arguments or in-app harness UI. It can reset persisted state and seed deterministic
 fixture graphs into the same SwiftData store files the real app uses.
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
    case baselineThreeWindows = "baseline-three-windows"
    case commentaryModule = "commentary-module"
    case commentaryModuleThreeWindows = "commentary-module-three-windows"
    case searchIndexed = "search-indexed"
    case searchMultiTranslation = "search-multi-translation"
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
    case syncNextCloud = "sync-nextcloud"
    case syncNextCloudBookmarksEnabled = "sync-nextcloud-bookmarks-enabled"
    case displayColorsCustom = "display-colors-custom"
    case downloadsRowOrder = "downloads-row-order"
}

/// Parsed CLI arguments for one fixture-tool invocation.
private struct ToolArguments {
    let command: ToolCommand
    let dataContainerURL: URL
    let bundleIdentifier: String
    let scenario: FixtureScenario?

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
    }
}

/// High-level errors emitted by the fixture tool.
private enum FixtureToolError: LocalizedError {
    case usage(String)
    case sqlite(String)
    case missingBundledSwordResources(String)
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
        case .missingBundledSwordResources(let path):
            return "Fixture seeding could not find bundled SWORD resources at '\(path)'."
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
    let bundleIdentifier: String
    let applicationSupportURL: URL
    let documentsURL: URL
    let preferencesURL: URL
    let cloudStoreURL: URL
    let localStoreURL: URL

    /**
     Creates the derived simulator-container paths used by the tool.
     *
     * - Parameters:
     *   - dataContainerURL: Root data container returned by `simctl get_app_container ... data`.
     *   - bundleIdentifier: App bundle identifier whose preferences file should be managed.
     */
    init(dataContainerURL: URL, bundleIdentifier: String) {
        self.dataContainerURL = dataContainerURL
        self.bundleIdentifier = bundleIdentifier
        self.applicationSupportURL = dataContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        self.documentsURL = dataContainerURL.appendingPathComponent("Documents", isDirectory: true)
        self.preferencesURL = dataContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
        self.cloudStoreURL = applicationSupportURL.appendingPathComponent("AndBible.store", isDirectory: false)
        self.localStoreURL = applicationSupportURL.appendingPathComponent("LocalStore.store", isDirectory: false)
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
     Deletes the app's persisted SwiftData stores, search index, SWORD install metadata, and
     preferences file.
     *
     * - Throws: Filesystem errors only when creating the parent directories fails.
     */
    private func resetContainer() throws {
        let paths = FixturePaths(
            dataContainerURL: arguments.dataContainerURL,
            bundleIdentifier: arguments.bundleIdentifier
        )
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: paths.applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: paths.documentsURL, withIntermediateDirectories: true)

        try removeSQLiteFamily(at: paths.cloudStoreURL)
        try removeSQLiteFamily(at: paths.localStoreURL)
        try removeSQLiteFamily(at: paths.applicationSupportURL.appendingPathComponent("CloudStore.store"))
        try removeSQLiteFamily(at: paths.documentsURL.appendingPathComponent("search_indexes.sqlite"))
        let installManagerURL = paths.documentsURL.appendingPathComponent("sword_install", isDirectory: true)
        if fileManager.fileExists(atPath: installManagerURL.path) {
            try fileManager.removeItem(at: installManagerURL)
        }
        try removeUITestSwordModules(from: paths)
        if fileManager.fileExists(atPath: paths.preferencesURL.path) {
            try fileManager.removeItem(at: paths.preferencesURL)
        }
    }

    /**
     Opens the simulator store files and writes one deterministic fixture scenario.
     *
     * - Parameter scenario: Named scenario describing the persisted graph to seed.
     * - Throws: SwiftData or validation errors when the store graph cannot be prepared.
     */
    private func seedScenario(_ scenario: FixtureScenario) throws {
        let paths = FixturePaths(
            dataContainerURL: arguments.dataContainerURL,
            bundleIdentifier: arguments.bundleIdentifier
        )
        let context = try FixtureContext(paths: paths, bundleIdentifier: arguments.bundleIdentifier)
        try context.seed(scenario)
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

     Baseline fixture resets intentionally leave bundled KJV in place, but scenario-local modules
     must not leak into later grouped test runs that use the same simulator.
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
            swordURL.appendingPathComponent("modules/comments/rawcom/000uitestcomm", isDirectory: true),
            swordURL.appendingPathComponent("modules/comments/rawcom/uitestcomm", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/aatestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/rawtext/uitestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/aatestweb", isDirectory: true),
            swordURL.appendingPathComponent("modules/texts/ztext/uitestweb", isDirectory: true),
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
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
    private var swordManager: SwordManager?

    /**
     Creates the store-backed fixture writer for one simulator container.
     *
     * - Parameters:
     *   - paths: Resolved simulator data-container paths.
     *   - bundleIdentifier: App bundle identifier used for remote-sync device folder naming.
     * - Throws: SwiftData initialization errors when the container cannot be opened.
     */
    init(paths: FixturePaths, bundleIdentifier: String) throws {
        self.paths = paths
        try fileManager.createDirectory(at: paths.applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.documentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: paths.preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let cloudModels: [any PersistentModel.Type] = [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
        ]
        let localModels: [any PersistentModel.Type] = [
            Repository.self,
            Setting.self,
        ]

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
     * - Throws: Validation errors when the baseline workspace graph cannot be created.
     */
    func seed(_ scenario: FixtureScenario) throws {
        let baseline = try ensureBaseline()

        switch scenario {
        case .baseline:
            break
        case .baselineThreeWindows:
            try ensureVisibleBibleWindowCount(3, baseline: baseline)
        case .commentaryModule:
            try seedUITestCommentaryModule()
        case .commentaryModuleThreeWindows:
            try ensureVisibleBibleWindowCount(3, baseline: baseline)
            try seedUITestCommentaryModule()
        case .searchIndexed:
            try seedBundledSearchIndex()
        case .searchMultiTranslation:
            try seedUITestBibleModule()
            try seedMultiTranslationSearchIndex()
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
        case .syncNextCloud:
            seedSyncNextCloud(enabledCategories: [])
        case .syncNextCloudBookmarksEnabled:
            seedSyncNextCloud(enabledCategories: [.bookmarks])
        case .displayColorsCustom:
            seedCustomColorSettings()
        case .downloadsRowOrder:
            try seedDownloadsRowOrderCatalog()
        }

        try modelContext.save()
        try writePreferences(["icloud_sync_enabled": false])
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
     Seeds a deterministic Downloads catalog that catches row-order regressions during install state.

     Android updates the tapped document row in place when a download starts; it does not rebuild and
     status-sort the list until filter data is rebuilt. This fixture writes a single local-only source
     and fresh cache containing installed KJV followed by two installable Bible rows, so the UI smoke
     can tap the last row and assert that it does not jump to Android's `BEING_INSTALLED` sort bucket.
     The seeded source points at a TEST-NET address and is never refreshed automatically because the
     cache is fresh; if the test taps install, the real download task stays active long enough for
     the smoke test to observe Android's in-place progress state without touching a live repository.
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
        HTTPSource=\(sourceName)|192.0.2.1|/catalog
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
                    dataPath: "./modules/texts/rawtext/uitestdlwarn/",
                    modDrv: "RawText",
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
        description: String,
        dataPath: String,
        modDrv: String,
        version: String,
        sourceName: String
    ) -> CachedDownloadModuleFixture {
        let normalizedDataPath = dataPath.hasPrefix("./") ? dataPath : "./\(dataPath)"
        let confContent = """
        [\(name)]
        Description=\(description)
        DataPath=\(normalizedDataPath)
        ModDrv=\(modDrv)
        Category=Biblical Texts
        Encoding=UTF-8
        Lang=en
        Version=\(version)
        """
        return CachedDownloadModuleFixture(
            name: name,
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
     Seeds a minimal bundled KJV FTS index so Search UI tests start from a ready state.
     *
     * The seeded rows are intentionally narrow: they cover the current Search UI assertions for
     * bundled queries (`earth`, `earth void`, `jesus`, and `noah`) without forcing UI tests to
     * wait for runtime index creation on fresh simulators.
     *
     * - Throws: `FixtureToolError.sqlite` when the search-index database cannot be created or
     *   written.
     */
    private func seedBundledSearchIndex() throws {
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
        try executeSearchSQL("DELETE FROM verse_fts WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("DELETE FROM verse_strongs WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("DELETE FROM indexed_modules WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("BEGIN TRANSACTION", db: db)

        do {
            try insertSeededSearchRows(into: db)
            try insertSeededStrongRows(into: db)
            try recordSeededSearchModule(
                "KJV",
                into: db,
                verseCount: Int32(Self.seededSearchRows.count)
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
     * - Throws: `FixtureToolError.sqlite` when the search-index database cannot be created or
     *   written.
     */
    private func seedMultiTranslationSearchIndex() throws {
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
        for moduleName in ["KJV", "AATESTWEB", "UITESTWEB"] {
            try executeSearchSQL("DELETE FROM verse_fts WHERE module_name = '\(moduleName)'", db: db)
            try executeSearchSQL("DELETE FROM verse_strongs WHERE module_name = '\(moduleName)'", db: db)
            try executeSearchSQL("DELETE FROM indexed_modules WHERE module_name = '\(moduleName)'", db: db)
        }
        try executeSearchSQL("BEGIN TRANSACTION", db: db)

        do {
            let rows = Self.seededSearchRows + Self.seededMultiTranslationSearchRows
            try insertSeededSearchRows(rows, into: db)
            try insertSeededStrongRows(into: db)
            for moduleName in Set(rows.map { $0.moduleName }).sorted() {
                let verseCount = rows.filter { $0.moduleName == moduleName }.count
                try recordSeededSearchModule(moduleName, into: db, verseCount: Int32(verseCount))
            }
            try executeSearchSQL("COMMIT", db: db)
        } catch {
            _ = try? executeSearchSQL("ROLLBACK", db: db)
            throw error
        }
    }

    /**
     Inserts the deterministic FTS rows used by Search UI fixtures.
     *
     * - Parameter db: Open SQLite handle for `search_indexes.sqlite`.
     * - Throws: `FixtureToolError.sqlite` when row insertion fails.
     */
    private func insertSeededSearchRows(into db: OpaquePointer) throws {
        try insertSeededSearchRows(Self.seededSearchRows, into: db)
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
        _ rows: [(verseKey: String, plainText: String, moduleName: String)],
        into db: OpaquePointer
    ) throws {
        let sql = """
            INSERT INTO verse_fts (verse_key, plain_text, module_name, entry_order)
            VALUES (?, ?, ?, ?)
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
            sqlite3_bind_text(statement, 1, row.verseKey, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.plainText, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.moduleName, -1, sqliteTransient)
            sqlite3_bind_int(statement, 4, Int32(entryOrder))
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
            INSERT OR IGNORE INTO verse_strongs (module_name, token, verse_key, entry_order)
            VALUES (?, ?, ?, ?)
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
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.moduleName, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.token, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.verseKey, -1, sqliteTransient)
            sqlite3_bind_int(statement, 4, Int32(row.entryOrder))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(
                    from: db,
                    fallback: "Unable to insert seeded Strong's row '\(row.verseKey)'."
                )
            }
        }
    }

    /**
     Records the seeded module metadata expected by `SearchIndexService.hasIndex`.

     The schema version comes from production `SearchIndexService` so fixture-generated search
     databases remain valid when the app intentionally invalidates older index formats.
     *
     * - Parameters:
     *   - moduleName: Module abbreviation to record as indexed.
     *   - db: Open SQLite handle for `search_indexes.sqlite`.
     *   - verseCount: Number of seeded verse rows for the module.
     * - Throws: `FixtureToolError.sqlite` when the metadata row cannot be written.
     */
    private func recordSeededSearchModule(_ moduleName: String, into db: OpaquePointer, verseCount: Int32) throws {
        let sql = """
            INSERT OR REPLACE INTO indexed_modules (module_name, verse_count, indexed_at, schema_version)
            VALUES (?, ?, datetime('now'), ?)
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

        sqlite3_bind_text(statement, 1, moduleName, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, verseCount)
        sqlite3_bind_int(statement, 3, Int32(SearchIndexService.currentSchemaVersion))

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
                verse_key,
                plain_text,
                module_name UNINDEXED,
                entry_order UNINDEXED,
                tokenize='unicode61'
            )
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS verse_strongs (
                module_name TEXT NOT NULL,
                token TEXT NOT NULL,
                verse_key TEXT NOT NULL,
                entry_order INTEGER NOT NULL,
                PRIMARY KEY (module_name, token, verse_key)
            )
        """, db: db)
        try executeSearchSQL("""
            CREATE INDEX IF NOT EXISTS idx_verse_strongs_module_token
            ON verse_strongs (module_name, token, entry_order)
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER DEFAULT 0,
                indexed_at TEXT,
                schema_version INTEGER DEFAULT 1
            )
        """, db: db)
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
     SQLite row set preseeded into the bundled KJV search index.
     */
    private static let seededSearchRows: [(verseKey: String, plainText: String, moduleName: String)] = [
        (
            verseKey: "Genesis 1:2",
            plainText: "And the earth was without form, and void; and darkness was upon the face of the deep.",
            moduleName: "KJV"
        ),
        (
            verseKey: "Genesis 6:8",
            plainText: "But Noah found grace in the eyes of the LORD.",
            moduleName: "KJV"
        ),
        (
            verseKey: "Matthew 1:1",
            plainText: "The book of the generation of Jesus Christ, the son of David, the son of Abraham.",
            moduleName: "KJV"
        ),
    ]

    /**
     SQLite rows preseeded into the bundled KJV Strong's index facet.

     The token is attached to `Genesis 1:2`, which already exists in `seededSearchRows`; this keeps
     Strong's fixture coverage without changing the deterministic ordinary-text result totals for
     broad `earth` searches.
     */
    private static let seededStrongRows: [(verseKey: String, token: String, moduleName: String, entryOrder: Int)] = [
        (
            verseKey: "Genesis 1:2",
            token: "H0430",
            moduleName: "KJV",
            entryOrder: 0
        ),
    ]

    /**
     Additional deterministic rows used only by the grouped multi-translation Search fixture.
     */
    private static let seededMultiTranslationSearchRows: [(verseKey: String, plainText: String, moduleName: String)] = [
        (
            verseKey: "Genesis 1:2",
            plainText: "The earth had become formless and empty, and darkness was on the surface of the deep.",
            moduleName: "AATESTWEB"
        ),
        (
            verseKey: "John 3:16",
            plainText: "For God so loved the earth that the deterministic fixture can prove grouped search totals.",
            moduleName: "AATESTWEB"
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
     therefore clones the bundled KJV module data under deterministic `AATESTWEB` metadata instead of
     publishing an empty RawText shell that Android/JSword-style discovery would reject.
     */
    private func seedUITestBibleModule() throws {
        let swordURL = paths.documentsURL.appendingPathComponent("sword", isDirectory: true)
        let modsDURL = swordURL.appendingPathComponent("mods.d", isDirectory: true)
        let dataURL = swordURL.appendingPathComponent(
            "modules/texts/ztext/aatestweb",
            isDirectory: true
        )
        let sourceDataURL = try bundledSwordResourceURL()
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

     The production bundle currently contains only KJV. Tests that exercise commentary switching
     need a deterministic installed commentary row without redistributing another real module.
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
     Resolves the repo-bundled SWORD resource directory used by the app at first launch.

     The host fixture tool runs outside the app bundle, so it cannot use `Bundle.main`. Resolving from
     `#filePath` keeps the fixture tied to the checked-out resources that Xcode also packages into
     the app.

     - Returns: Repository `AndBible/Resources/sword` directory.
     - Throws: `FixtureToolError.missingBundledSwordResources` when the resources are unavailable.
     */
    private func bundledSwordResourceURL() throws -> URL {
        var candidateRootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidateRootURL.path != candidateRootURL.deletingLastPathComponent().path {
            let bundledSwordURL = candidateRootURL
                .appendingPathComponent("AndBible", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("sword", isDirectory: true)
            if fileManager.fileExists(atPath: bundledSwordURL.path) {
                return bundledSwordURL
            }
            candidateRootURL.deleteLastPathComponent()
        }

        let fallbackPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
            .path
        throw FixtureToolError.missingBundledSwordResources(fallbackPath)
    }

    /**
     Ensures the simulator SWORD directory contains the bundled KJV module.

     UI fixture commands can run before app launch has copied bundled modules. Bookmark fixtures need
     KJV available immediately so their persisted ordinals are produced by SWORD instead of by a
     static approximation.

     - Returns: Simulator document `sword` directory.
     - Throws: Filesystem errors or `FixtureToolError.missingBundledSwordResources`.
     */
    @discardableResult
    private func ensureBundledKJVSwordModuleAvailable() throws -> URL {
        let sourceSwordURL = try bundledSwordResourceURL()
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
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "UI_Test_My_Notes_Note")
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
            content: "# UI Test My Document\n\nSeeded body for drawer routing coverage."
        )

        page.pageContent = content
        page.document = document
        document.pages = [page]
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
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
     - Throws: `FixtureToolError` when the bundled KJV module or verse cannot be resolved.
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
     Loads the bundled KJV module from the simulator SWORD directory.

     The returned module borrows handles owned by `SwordManager`, so the manager is cached for the
     lifetime of the fixture context.

     - Returns: Loaded bundled KJV SWORD module.
     - Throws: `FixtureToolError.missingSwordModule` if SWORD cannot load KJV.
     */
    private func kjvSwordModule() throws -> SwordModule {
        let swordURL = try ensureBundledKJVSwordModuleAvailable()
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
     protected by `testBundledKJVVerseOrdinalsUseIntroInclusiveVersification` while avoiding the
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
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: ordinalStart,
            endOrdinal: ordinalStart,
            v11n: "KJVA"
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
     Writes a minimal preferences plist into the simulator container.
     *
     * - Parameter values: Dictionary encoded into the app preferences file.
     * - Throws: Filesystem or plist-serialization errors.
     */
    private func writePreferences(_ values: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        try data.write(to: paths.preferencesURL, options: .atomic)
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
