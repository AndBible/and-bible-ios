import Foundation
import SQLite3
import SwiftData
import BibleCore

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
    case searchIndexed = "search-indexed"
    case bookmarkNavigation = "bookmark-navigation"
    case bookmarkMultiRow = "bookmark-multirow"
    case bookmarkFilter = "bookmark-filter"
    case bookmarkRowLabel = "bookmark-row-label"
    case bookmarkStudyPad = "bookmark-studypad"
    case historySingle = "history-single"
    case historyMultiRow = "history-multirow"
    case myNotesSingle = "my-notes-single"
    case syncNextCloud = "sync-nextcloud"
    case syncNextCloudBookmarksEnabled = "sync-nextcloud-bookmarks-enabled"
    case displayColorsCustom = "display-colors-custom"
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
    case missingWorkspace
    case missingWindow
    case missingPageManager

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .sqlite(let message):
            return message
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
     Deletes the app's persisted SwiftData stores, search index, and preferences file.
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
        case .searchIndexed:
            try seedBundledSearchIndex()
        case .bookmarkNavigation:
            seedBookmarkNavigation()
        case .bookmarkMultiRow:
            seedBookmarkMultiRow()
        case .bookmarkFilter:
            seedBookmarkFilter()
        case .bookmarkRowLabel:
            seedBookmarkRowLabel()
        case .bookmarkStudyPad:
            seedBookmarkStudyPad()
        case .historySingle:
            seedHistorySingle(window: baseline.window)
        case .historyMultiRow:
            seedHistoryMultiRow(window: baseline.window)
        case .myNotesSingle:
            seedMyNotesSingle()
        case .syncNextCloud:
            seedSyncNextCloud(enabledCategories: [])
        case .syncNextCloudBookmarksEnabled:
            seedSyncNextCloud(enabledCategories: [.bookmarks])
        case .displayColorsCustom:
            seedCustomColorSettings(pageManager: baseline.pageManager)
        }

        try modelContext.save()
        try writePreferences(["icloud_sync_enabled": false])
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

        try executeSearchSQL("PRAGMA journal_mode=WAL", db: db)
        try executeSearchSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                verse_key,
                plain_text,
                module_name UNINDEXED,
                tokenize='unicode61'
            )
        """, db: db)
        try executeSearchSQL("""
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER DEFAULT 0,
                indexed_at TEXT,
                schema_version INTEGER DEFAULT 1
            )
        """, db: db)
        try executeSearchSQL("DELETE FROM verse_fts WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("DELETE FROM indexed_modules WHERE module_name = 'KJV'", db: db)
        try executeSearchSQL("BEGIN TRANSACTION", db: db)

        do {
            try insertSeededSearchRows(into: db)
            try recordSeededSearchModule(into: db, verseCount: Int32(Self.seededSearchRows.count))
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
        let sql = "INSERT INTO verse_fts (verse_key, plain_text, module_name) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(
                from: db,
                fallback: "Unable to prepare seeded search row insert statement."
            )
        }
        defer { sqlite3_finalize(statement) }

        for row in Self.seededSearchRows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, row.verseKey, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, row.plainText, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, row.moduleName, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(
                    from: db,
                    fallback: "Unable to insert seeded search row '\(row.verseKey)'."
                )
            }
        }
    }

    /**
     Records the seeded module metadata expected by `SearchIndexService.hasIndex`.
     *
     * - Parameters:
     *   - db: Open SQLite handle for `search_indexes.sqlite`.
     *   - verseCount: Number of seeded verse rows for the module.
     * - Throws: `FixtureToolError.sqlite` when the metadata row cannot be written.
     */
    private func recordSeededSearchModule(into db: OpaquePointer, verseCount: Int32) throws {
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

        sqlite3_bind_text(statement, 1, "KJV", -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, verseCount)
        sqlite3_bind_int(statement, 3, 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(
                from: db,
                fallback: "Unable to record seeded search module metadata."
            )
        }
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

    /// SQLite destructor token instructing SQLite to copy bound text values.
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
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
     Seeds one bookmark that should navigate from Genesis 1 to Exodus 2.
     */
    private func seedBookmarkNavigation() {
        _ = createBibleBookmark(
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
    private func seedBookmarkMultiRow() {
        _ = createBibleBookmark(
            bookName: "Matthew",
            chapter: 3,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 10)
        )
        _ = createBibleBookmark(
            bookName: "Exodus",
            chapter: 2,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
    }

    /**
     Seeds two labeled bookmark rows used by filter-reset workflows.
     */
    private func seedBookmarkFilter() {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        let secondaryLabel = ensureUserLabel(name: "Other Label", color: 0xFFFFCC99)
        _ = createBibleBookmark(
            bookName: "Exodus",
            chapter: 2,
            label: secondaryLabel,
            note: nil,
            createdAt: seededDate(offset: 10)
        )
        _ = createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            label: uiTestLabel,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
    }

    /**
     Seeds one bookmark assigned to the primary UI-test label.
     */
    private func seedBookmarkRowLabel() {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        _ = createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            label: uiTestLabel,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
    }

    /**
     Seeds one label-backed bookmark and an initial empty StudyPad entry.
     */
    private func seedBookmarkStudyPad() {
        let uiTestLabel = ensureUserLabel(name: "UI Test Seed", color: 0xFF91A7FF)
        _ = createBibleBookmark(
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
    private func seedMyNotesSingle() {
        let bookmark = createBibleBookmark(
            bookName: "Genesis",
            chapter: 1,
            labelName: nil,
            note: nil,
            createdAt: seededDate(offset: 20)
        )
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "UI_Test_My_Notes_Note")
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
     Seeds one non-default color tuple into the active page manager's text-display settings.
     *
     * - Parameter pageManager: Active page manager whose display settings should be overridden.
     */
    private func seedCustomColorSettings(pageManager: PageManager) {
        var settings = pageManager.textDisplaySettings ?? TextDisplaySettings()
        settings.dayTextColor = 0xFF112233
        settings.dayBackground = 0xFFFAF4E8
        settings.dayNoise = 7
        settings.nightTextColor = 0xFFF1E7D0
        settings.nightBackground = 0xFF101820
        settings.nightNoise = 5
        pageManager.textDisplaySettings = settings
    }

    /**
     Creates one deterministic Bible bookmark with optional label and note state.
     *
     * - Parameters:
     *   - bookName: Human-readable book name surfaced by the bookmark list.
     *   - chapter: One-based chapter number. The test bookmark UI only needs chapter-level fidelity.
     *   - label: Optional user label that should be assigned as the primary label.
     *   - note: Optional bookmark note.
     *   - createdAt: Deterministic creation date used to control list ordering.
     * - Returns: The persisted bookmark.
     */
    @discardableResult
    private func createBibleBookmark(
        bookName: String,
        chapter: Int,
        label: Label?,
        note: String?,
        createdAt: Date
    ) -> BibleBookmark {
        let ordinalStart = max((chapter - 1) * 40, 0)
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
    ) -> BibleBookmark {
        let label = labelName.map { ensureUserLabel(name: $0, color: Label.defaultColor) }
        return createBibleBookmark(
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
