// AIPromptManagementView.swift -- Prompt, category, source, and behavior editing

import BibleCore
import SwiftData
import SwiftUI
import SwordKit
import UniformTypeIdentifiers

/** Stable identities for Android's virtual and persisted prompt groups. */
enum AIPromptManagementGroupID: Hashable {
    /// Virtual group containing visible favorite prompts.
    case favorites
    /// Virtual group containing prompts whose category cannot be resolved.
    case uncategorized
    /// Built-in or user category identified by its persisted UUID.
    case category(UUID)
}

/**
 One category-group snapshot rendered by prompt management.

 The snapshot separates category resolution from SwiftUI so Android's ordering, empty-category,
 filtering, and hidden-category contracts can be tested without rendering a list.
 */
struct AIPromptManagementGroup: Identifiable {
    /// Stable virtual or persisted identity.
    let id: AIPromptManagementGroupID
    /// Persisted category metadata, or `nil` for Favorites and Uncategorized.
    let category: PromptCategory?
    /// Visible prompts in Android repository order.
    let entries: [ResolvedAgentPrompt]
    /// Whether Android starts this category collapsed and renders its header dimmed.
    let isHidden: Bool
    /// Whether category mutation is limited to built-in hide/show behavior.
    let isBuiltInCategory: Bool
}

/** Pure Android parity rules shared by prompt-list presentation and focused tests. */
enum AIPromptManagementBehavior {
    /**
     Builds Favorites, Uncategorized, and ordered persisted category groups.

     - Parameters:
       - entries: Effective prompts in repository order, including hidden built-ins.
       - categories: Built-in and user categories before cross-source ordering.
       - favoriteIDs: Current synced favorite identities.
       - hiddenBuiltInPromptIDs: Built-in prompt identities removed from settings presentation.
       - hiddenBuiltInCategoryIDs: Built-in categories hidden from AI action surfaces.
     - Returns: Android-ordered groups. Empty user categories are retained; empty built-in categories
       and an empty Favorites or Uncategorized group are omitted.
     - Side effects: None; input model objects are read but never mutated.
     - Note: Equal category order values retain repository order, matching Kotlin's stable `sortedBy`.
     */
    static func groups(
        entries: [ResolvedAgentPrompt],
        categories: [PromptCategory],
        favoriteIDs: Set<UUID>,
        hiddenBuiltInPromptIDs: Set<UUID>,
        hiddenBuiltInCategoryIDs: Set<UUID>
    ) -> [AIPromptManagementGroup] {
        let visibleEntries = entries.filter {
            $0.origin != .builtIn || !hiddenBuiltInPromptIDs.contains($0.prompt.id)
        }
        let knownCategoryIDs = Set(categories.map(\.id))
        let builtInCategoryIDs = Set(BuiltInPromptCatalog.categories().map(\.id))

        func resolvedCategoryID(for entry: ResolvedAgentPrompt) -> UUID? {
            guard let categoryID = entry.prompt.categoryId,
                  knownCategoryIDs.contains(categoryID) else {
                return nil
            }
            return categoryID
        }

        var result: [AIPromptManagementGroup] = []
        let favorites = visibleEntries.filter { favoriteIDs.contains($0.prompt.id) }
        if !favorites.isEmpty {
            result.append(AIPromptManagementGroup(
                id: .favorites,
                category: nil,
                entries: favorites,
                isHidden: false,
                isBuiltInCategory: false
            ))
        }

        let uncategorized = visibleEntries.filter { resolvedCategoryID(for: $0) == nil }
        if !uncategorized.isEmpty {
            result.append(AIPromptManagementGroup(
                id: .uncategorized,
                category: nil,
                entries: uncategorized,
                isHidden: false,
                isBuiltInCategory: false
            ))
        }

        let orderedCategories = categories.enumerated().sorted { lhs, rhs in
            if lhs.element.orderNumber != rhs.element.orderNumber {
                return lhs.element.orderNumber < rhs.element.orderNumber
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var emittedCategoryIDs: Set<UUID> = []
        for category in orderedCategories where emittedCategoryIDs.insert(category.id).inserted {
            let categoryEntries = visibleEntries.filter {
                resolvedCategoryID(for: $0) == category.id
            }
            let isBuiltIn = builtInCategoryIDs.contains(category.id)
            guard !categoryEntries.isEmpty || !isBuiltIn else { continue }
            result.append(AIPromptManagementGroup(
                id: .category(category.id),
                category: category,
                entries: categoryEntries,
                isHidden: category.hidden || hiddenBuiltInCategoryIDs.contains(category.id),
                isBuiltInCategory: isBuiltIn
            ))
        }
        return result
    }

    /**
     Finds the adjacent editable prompt in the same persisted category.

     - Parameters:
       - promptID: User prompt to move.
       - offset: Relative sibling offset, normally `-1` or `1`.
       - prompts: User prompts in current Android display order.
     - Returns: Target sibling identity, or `nil` at category boundaries or for a missing prompt.
     - Side effects: None.
     */
    static func siblingMoveTargetID(
        promptID: UUID,
        offset: Int,
        prompts: [AgentPrompt]
    ) -> UUID? {
        guard let source = prompts.first(where: { $0.id == promptID }) else { return nil }
        let siblings = prompts.filter { $0.categoryId == source.categoryId }
        guard let sourceIndex = siblings.firstIndex(where: { $0.id == promptID }) else { return nil }
        let targetIndex = sourceIndex + offset
        guard siblings.indices.contains(targetIndex) else { return nil }
        return siblings[targetIndex].id
    }

    /**
     Reorders one prompt only among editable siblings in its actual category.

     - Parameters:
       - promptID: User prompt to move.
       - offset: Relative sibling offset, normally `-1` or `1`.
       - prompts: Managed user prompts in current display order.
     - Returns: `true` when order values changed; otherwise `false`.
     - Side effects: Swaps `orderNumber` only on the source and adjacent sibling. Persistence remains
       the caller's responsibility.
     */
    @discardableResult
    static func movePrompt(
        promptID: UUID,
        offset: Int,
        prompts: [AgentPrompt]
    ) -> Bool {
        guard let source = prompts.first(where: { $0.id == promptID }) else { return false }
        let siblings = prompts.filter { $0.categoryId == source.categoryId }
        guard let sourceIndex = siblings.firstIndex(where: { $0.id == promptID }) else { return false }
        let targetIndex = sourceIndex + offset
        guard siblings.indices.contains(targetIndex) else { return false }
        let target = siblings[targetIndex]
        let sourceOrder = source.orderNumber
        source.orderNumber = target.orderNumber
        target.orderNumber = sourceOrder
        return true
    }
}

/** Android-compatible semicolon CSV encoder for editable prompts. */
enum AIPromptCSVEncoder {
    /// Column order consumed by Android's `PromptCsvUtils`.
    static let headers = [
        "name", "description", "promptTemplate", "showIn", "orderNumber",
        "strictContextMatching", "permissionMode", "allowedTools", "deniedTools",
        "configuredModelId", "id", "createdAt", "bibleOnly", "category",
    ]

    /**
     Encodes user prompts with Android's headers, UTC timestamp, set raw values, and category names.

     - Parameters:
       - prompts: User-owned prompts to export in display order.
       - categories: Category catalog used to resolve the optional category-name column.
     - Returns: UTF-8 semicolon CSV bytes ending in a newline.
     - Side effects: None.
     - Failure modes: Encoding Swift strings as UTF-8 cannot fail.
     */
    static func encode(prompts: [AgentPrompt], categories: [PromptCategory]) -> Data {
        let categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        var rows = [headers.joined(separator: ";")]
        rows.append(contentsOf: prompts.map { prompt in
            let showIn = prompt.showIn.map(\.rawValue).sorted().joined(separator: ",")
            let permissionMode = prompt.permissionMode?.rawValue ?? ""
            let allowedTools = prompt.allowedTools?.map(\.rawValue).sorted().joined(separator: ",") ?? ""
            let deniedTools = prompt.deniedTools?.map(\.rawValue).sorted().joined(separator: ",") ?? ""
            let configuredModelID = prompt.configuredModelId?.uuidString.lowercased() ?? ""
            let createdAt = formatter.string(from: Date(
                timeIntervalSince1970: Double(prompt.createdAtMilliseconds) / 1_000
            ))
            let categoryName = prompt.categoryId.flatMap { categoryNames[$0] } ?? ""
            let values: [String] = [
                prompt.name,
                prompt.promptDescription ?? "",
                prompt.promptTemplate,
                showIn,
                String(prompt.orderNumber),
                prompt.strictContextMatching ? "true" : "false",
                permissionMode,
                allowedTools,
                deniedTools,
                configuredModelID,
                prompt.id.uuidString.lowercased(),
                createdAt,
                prompt.bibleOnly ? "true" : "false",
                categoryName,
            ]
            return values.map(escape).joined(separator: ";")
        })
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }

    /** Escapes one field according to Android's semicolon CSV writer. */
    private static func escape(_ value: String) -> String {
        guard value.contains(";") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/** Category metadata aligned with valid rows returned by the shared prompt CSV parser. */
enum AIPromptCSVCategoryMetadataDecoder {
    /**
     Reads Android's optional category column without duplicating prompt-field decoding.

     - Parameter data: UTF-8 semicolon CSV bytes passed to `PromptCSVParser`.
     - Returns: One optional category name per parser-valid prompt row, in matching order.
     - Side effects: None.
     - Throws: `PromptCSVError.invalidUTF8` or `.emptyFile` for the same fatal inputs as the shared
       prompt parser.
     */
    static func categoryNames(from data: Data) throws -> [String?] {
        guard let source = String(data: data, encoding: .utf8) else {
            throw PromptCSVError.invalidUTF8
        }
        var scanner = AIPromptCSVRecordScanner(source: source)
        guard let headers = scanner.nextRecord() else { throw PromptCSVError.emptyFile }
        let indexes = Dictionary(uniqueKeysWithValues: headers.enumerated().map {
            ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset)
        })

        func value(_ key: String, values: [String]) -> String? {
            guard let index = indexes[key], values.indices.contains(index) else { return nil }
            return values[index]
        }

        var names: [String?] = []
        var rowCount = 0
        while rowCount < PromptCSVParser.maximumRows, let values = scanner.nextRecord() {
            rowCount += 1
            guard values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let name = value("name", values: values)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let template = value("promptTemplate", values: values),
                  !template.isEmpty else {
                continue
            }
            let category = value("category", values: values)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            names.append(category.flatMap { $0.isEmpty ? nil : $0 })
        }
        return names
    }
}

/** Stateful semicolon CSV scanner used only to align category metadata with shared parser rows. */
private struct AIPromptCSVRecordScanner {
    /// Complete decoded source characters.
    private let characters: [Character]
    /// Current source offset.
    private var index = 0

    /** Creates a scanner without reading or mutating external state. */
    init(source: String) {
        characters = Array(source)
    }

    /**
     Returns the next record while preserving quoted semicolons, escaped quotes, and line breaks.

     - Returns: Parsed fields, or `nil` after all source characters are consumed.
     - Side effects: Advances this scanner's in-memory offset.
     - Failure modes: Unterminated quotes consume the remaining input, matching Android's tolerant
       prompt CSV reader.
     */
    mutating func nextRecord() -> [String]? {
        guard index < characters.count else { return nil }
        var fields: [String] = []
        var field = ""
        var quoted = false
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" {
                if quoted, index < characters.count, characters[index] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == ";", !quoted {
                fields.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                if character == "\r", index < characters.count, characters[index] == "\n" {
                    index += 1
                }
                fields.append(field)
                return fields
            } else {
                field.append(character)
            }
        }
        fields.append(field)
        return fields
    }
}

/** File-document wrapper used by SwiftUI's prompt CSV destination picker. */
struct AIPromptCSVTransferDocument: FileDocument {
    /// CSV and plain-text types accepted by Android's prompt importer.
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .plainText]
    /// Immutable UTF-8 prompt CSV payload.
    let data: Data

    /** Creates an export document from already encoded bytes without file I/O. */
    init(data: Data) {
        self.data = data
    }

    /**
     Reads prompt CSV bytes supplied by SwiftUI's document infrastructure.

     - Parameter configuration: Selected regular-file wrapper.
     - Side effects: Reads the wrapper payload into memory.
     - Throws: Cocoa file errors when no regular-file bytes are available.
     */
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    /**
     Supplies immutable prompt CSV bytes to SwiftUI's destination writer.

     - Parameter configuration: Export request metadata; no value affects the encoded payload.
     - Returns: Regular-file wrapper containing `data`.
     - Side effects: None; SwiftUI owns the eventual destination write.
     - Failure modes: In-memory wrapper construction cannot fail.
     */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/** Android's two prompt CSV import ownership choices. */
private enum AIPromptCSVImportMode {
    /// Create or update user-owned SwiftData prompts.
    case editable
    /// Install the CSV through the existing read-only Android prompt-pack service.
    case addOn
}

/** Mutable counters reported after editable prompt CSV import. */
private struct AIPromptCSVImportSummary {
    /// Newly inserted user prompts.
    var created = 0
    /// Existing user prompts replaced by matching identity.
    var updated = 0
    /// Rows rejected because identity ownership or persistence failed.
    var errors = 0
}

/**
 Prompt manager for built-in, add-on, and user-authored actions.

 Standalone callers receive the existing Manage AI Prompts destination. The configured AI Settings
 route mirrors Android's category-grouped list, pushed prompt/connection destinations, and dialog-
 based category, transfer, restore, help, and debug-reset actions. Prompt and category mutations save
 through the surrounding SwiftData context; CSV add-on installation may also mutate module storage.
 */
public struct AIPromptManagementView: View {
    /// Pops the standalone prompt activity when no explicit owner is supplied.
    @Environment(\.dismiss) private var dismiss
    /// Current appearance used by the shared app-owned overflow surface.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    private let swordManager: SwordManager?
    /// Device-only credential boundary when this list is Android's configured AI Settings root.
    private let settingsRootCredentialStore: AICredentialStore?
    /// Reader/workspace palette shared by the prompt manager and nested editor.
    private let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command supplied by the activity owner.
    private let onBack: (() -> Void)?
    /// Opens the configured Connection settings activity.
    private let onOpenConnection: (() -> Void)?
    /// Opens an existing or new prompt in the configured activity owner.
    private let onOpenPrompt: ((UUID?) -> Void)?

    @State private var revision = 0
    /// Prompt editor locally replacing the standalone manager, if any.
    @State private var locallyOpenedPromptID: UUID??
    /// Whether Android's toolbar overflow popup is visible.
    @State private var showsOverflowMenu = false
    @State private var failureMessage: String?
    @State private var deletingPromptID: UUID?
    /// Long-pressed prompt whose Android action list is currently visible.
    @State private var promptActionDialog: AIPromptActionDialogContext?
    /// Long-pressed category whose Android action list is currently visible.
    @State private var categoryActionDialog: AIPromptCategoryDialogContext?
    /// Groups collapsed by the user or by Android's hidden-category default.
    @State private var collapsedGroupIDs: Set<AIPromptManagementGroupID> = []
    /// Draft name entered by Android's New category dialog.
    @State private var newCategoryName = ""
    /// Whether the New category dialog is visible.
    @State private var showingNewCategory = false
    /// Category currently being renamed, if any.
    @State private var renamingCategoryID: UUID?
    /// Draft replacement name used by the rename dialog.
    @State private var categoryNameDraft = ""
    /// User category awaiting Android's two-disposition deletion dialog.
    @State private var deletingCategoryID: UUID?
    /// User prompt awaiting Android's move-to-category dialog.
    @State private var movingPromptID: UUID?
    /// Whether Android's editable-versus-add-on import choice is visible.
    @State private var showingImportOptions = false
    /// Ownership mode selected before opening the document picker.
    @State private var promptImportMode = AIPromptCSVImportMode.editable
    /// Whether the system CSV source picker is visible.
    @State private var showingPromptImporter = false
    /// Immutable prompt CSV bytes handed to the system destination picker.
    @State private var promptExportDocument: AIPromptCSVTransferDocument?
    /// Whether the system CSV destination picker is visible.
    @State private var showingPromptExporter = false
    /// Non-error completion or no-op feedback shown in an alert.
    @State private var noticeMessage: String?
    /// Android's app-owned AI Settings Help dialog.
    @State private var helpDialog: AIConfigurationDialog?
    /// Whether the debug-only destructive reset confirmation is visible.
    @State private var showingResetConfirmation = false

    /**
     Creates a standalone prompt manager with optional SWORD add-on discovery.

     - Parameter swordManager: Optional installed-module source for read-only prompt packs.
     - Side effects: None until prompt actions read or mutate the surrounding SwiftData context.
     - Failure modes: Repository failures are surfaced as localized alerts.
     */
    public init(swordManager: SwordManager? = nil) {
        self.swordManager = swordManager
        settingsRootCredentialStore = nil
        surfacePalette = .standard
        onBack = nil
        onOpenConnection = nil
        onOpenPrompt = nil
    }

    /**
     Creates Android's configured AI Settings root over the shared prompt list.

     - Parameters:
       - swordManager: Optional installed-module source for read-only prompt packs.
       - settingsRootCredentialStore: Device-only Keychain boundary forwarded to Connection settings.
       - surfacePalette: Palette inherited from the reader/workspace owner.
       - onBack: Explicit Android Up command.
       - onOpenConnection: Replaces the root with Connection settings.
       - onOpenPrompt: Replaces the root with a prompt editor.
     - Side effects: None until a prompt or connection destination performs an explicit mutation.
     - Failure modes: Prompt failures are shown locally; connection failures belong to that route.
     */
    init(
        swordManager: SwordManager?,
        settingsRootCredentialStore: AICredentialStore,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: @escaping () -> Void,
        onOpenConnection: @escaping () -> Void,
        onOpenPrompt: @escaping (UUID?) -> Void
    ) {
        self.swordManager = swordManager
        self.settingsRootCredentialStore = settingsRootCredentialStore
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onOpenConnection = onOpenConnection
        self.onOpenPrompt = onOpenPrompt
    }

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    private var repository: PromptRepository {
        PromptRepository(
            settingsStore: settingsStore,
            packProvider: swordManager.map { SwordPromptPackProvider(swordManager: $0) }
        )
    }
    private var entries: [ResolvedAgentPrompt] {
        (try? repository.allPromptsIncludingHidden()) ?? []
    }
    private var favoriteIDs: Set<UUID> {
        (try? repository.favoritePromptIDs()) ?? []
    }
    private var hiddenBuiltInIDs: Set<UUID> {
        (try? settingsStore.globalSettings().hiddenBuiltInPrompts) ?? []
    }
    /// Built-in category identities hidden from action menus but retained in this manager.
    private var hiddenBuiltInCategoryIDs: Set<UUID> {
        (try? settingsStore.globalSettings().hiddenBuiltInCategories) ?? []
    }
    /// Effective built-in and user categories before Android's cross-source sort.
    private var categories: [PromptCategory] {
        (try? repository.allCategories()) ?? []
    }
    /// Android-ordered snapshot consumed by the list and category dialogs.
    private var groups: [AIPromptManagementGroup] {
        AIPromptManagementBehavior.groups(
            entries: entries,
            categories: categories,
            favoriteIDs: favoriteIDs,
            hiddenBuiltInPromptIDs: hiddenBuiltInIDs,
            hiddenBuiltInCategoryIDs: hiddenBuiltInCategoryIDs
        )
    }
    /// Managed user prompts in the same order used to resolve category-local move boundaries.
    private var userPrompts: [AgentPrompt] {
        (try? settingsStore.userPrompts()) ?? []
    }

    public var body: some View {
        Group {
            if let localPrompt = locallyOpenedPromptID {
                AIPromptEditorView(
                    promptID: localPrompt,
                    swordManager: swordManager,
                    surfacePalette: surfacePalette,
                    onBack: { locallyOpenedPromptID = nil },
                    onChanged: refresh
                )
            } else {
                promptManagerActivity
            }
        }
        .fileImporter(
            isPresented: $showingPromptImporter,
            allowedContentTypes: AIPromptCSVTransferDocument.readableContentTypes,
            allowsMultipleSelection: false,
            onCompletion: importPromptSelection
        )
        .fileExporter(
            isPresented: $showingPromptExporter,
            document: promptExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: promptCSVFileName,
            onCompletion: completePromptExport
        )
        .aiConfigurationDialog(
            $helpDialog,
            credentialStore: settingsRootCredentialStore ?? .keychain()
        )
        .overlay {
            if let message = noticeMessage {
                AndroidDecisionDialog(title: String(localized: "ai_settings", defaultValue: "AI Settings"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { noticeMessage = nil }
                ])
            } else if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Full app-owned AI Settings/Manage Prompts activity matching Android's action bar and list. */
    private var promptManagerActivity: some View {
        ZStack {
            AndroidActivityScreen(
                title: settingsRootCredentialStore == nil
                    ? String(localized: "manage_prompts", defaultValue: "Manage AI Prompts")
                    : String(localized: "ai_settings", defaultValue: "AI Settings"),
                accessibilityIdentifier: "aiPromptManagementTopAppBar",
                palette: surfacePalette,
                onBack: performBack
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(localized: "new_prompt", defaultValue: "New prompt"),
                    accessibilityIdentifier: "aiNewPromptButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    openPrompt(nil)
                }

                if onOpenConnection != nil {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("DrawerSettings"),
                        accessibilityLabel: String(
                            localized: "ai_connection_settings",
                            defaultValue: "Connection settings"
                        ),
                        accessibilityIdentifier: "aiConnectionSettingsLink",
                        foregroundColor: surfacePalette.toolbarForegroundColor
                    ) {
                        onOpenConnection?()
                    }
                }

                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "aiPromptSettingsActionsMenu",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showsOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: "aiPromptSettingsOverflowAnchor")
            } content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            promptSection(group)
                        }

                        if entries.isEmpty {
                            Text(
                                String(
                                    localized: "manage_prompts_summary",
                                    defaultValue: "Create and edit AI prompts"
                                )
                            )
                            .font(.system(size: 17))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .multilineTextAlignment(.center)
                            .padding(32)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .id(revision)
                }
            }
            .accessibilityHidden(isPromptModalPresented)
            .disabled(isPromptModalPresented)

            promptDialogOverlay
        }
        .onAppear { resetCollapsedGroups() }
        .androidAnchoredPopupMenu(
            anchorID: "aiPromptSettingsOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 310,
            estimatedMenuHeight: 330,
            accessibilityIdentifier: "aiPromptSettingsOverflowMenu"
        ) {
            promptSettingsOverflowMenu
        }
    }

    /** Shared anchored popup containing Android's `SHOW_AS_ACTION_NEVER` prompt commands. */
    private var promptSettingsOverflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiPromptSettingsOverflowMenu",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                promptOverflowRow(
                    title: String(localized: "new_category", defaultValue: "New category"),
                    identifier: "aiNewCategoryMenuItem"
                ) {
                    newCategoryName = ""
                    showingNewCategory = true
                }
                promptOverflowRow(
                    title: String(localized: "export_prompts_csv", defaultValue: "Export prompts to CSV"),
                    identifier: "aiExportPromptsMenuItem",
                    action: preparePromptExport
                )
                promptOverflowRow(
                    title: String(localized: "import_prompts_csv", defaultValue: "Import prompts from CSV"),
                    identifier: "aiImportPromptsMenuItem"
                ) {
                    showingImportOptions = true
                }
                if !hiddenBuiltInIDs.isEmpty {
                    promptOverflowRow(
                        title: String(
                            localized: "ai_restore_hidden_prompts",
                            defaultValue: "Restore hidden prompts"
                        ),
                        identifier: "aiRestoreHiddenPromptsMenuItem",
                        action: restoreHiddenPrompts
                    )
                }
                #if DEBUG
                promptOverflowRow(
                    title: String(
                        localized: "reset_all_ai_settings",
                        defaultValue: "Reset all AI settings"
                    ),
                    identifier: "aiResetAllSettingsMenuItem"
                ) {
                    showingResetConfirmation = true
                }
                #endif
                promptOverflowRow(
                    title: String(localized: "help", defaultValue: "Help"),
                    identifier: "aiPromptHelpMenuItem"
                ) {
                    helpDialog = .help(.aiSettings)
                }
            }
        }
    }

    /** Builds one overflow row and consistently dismisses the shared popup before its command. */
    private func promptOverflowRow(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidPopupMenuRow(title: title, accessibilityIdentifier: identifier) {
            showsOverflowMenu = false
            action()
        }
    }

    /** Opens a prompt through the configured owner or the standalone app-owned replacement route. */
    private func openPrompt(_ promptID: UUID?) {
        if let onOpenPrompt {
            onOpenPrompt(promptID)
        } else {
            locallyOpenedPromptID = .some(promptID)
        }
    }

    /** Returns through the explicit activity owner or SwiftUI's standalone dismissal fallback. */
    private func performBack() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /// Whether one app-owned Android prompt-management dialog currently blocks the list.
    private var isPromptDialogPresented: Bool {
        promptActionDialog != nil
            || categoryActionDialog != nil
            || movingPromptID != nil
            || deletingCategoryID != nil
            || showingImportOptions
            || showingNewCategory
            || renamingCategoryID != nil
            || showingResetConfirmation
            || deletingPromptID != nil
    }

    /// Whether any Android prompt or shared information dialog currently owns interaction.
    private var isPromptModalPresented: Bool {
        isPromptDialogPresented || helpDialog != nil
    }

    /** Renders the highest-priority app-owned dialog represented by prompt-management state. */
    @ViewBuilder
    private var promptDialogOverlay: some View {
        if isPromptDialogPresented {
            AIPromptDialogOverlay(onDismiss: dismissPromptDialogs) {
                if let context = promptActionDialog {
                    AIPromptActionListDialog(
                        title: context.promptName,
                        actions: context.actions,
                        label: \.title,
                        onSelect: { handlePromptAction($0, context: context) }
                    )
                } else if let context = categoryActionDialog {
                    AIPromptActionListDialog(
                        title: context.categoryName,
                        actions: context.actions,
                        label: \.title,
                        onSelect: { handleCategoryAction($0, context: context) }
                    )
                } else if let movingPromptID {
                    AIPromptChoiceDialog(
                        title: String(localized: "move_to_category", defaultValue: "Move to category…"),
                        choices: [UUID?.none] + categories.map { Optional($0.id) },
                        label: { categoryID in
                            categoryID.flatMap { selectedID in
                                categories.first(where: { $0.id == selectedID })?.name
                            } ?? String(localized: "category_none", defaultValue: "No category")
                        },
                        onSelect: { movePrompt(movingPromptID, toCategory: $0) },
                        onCancel: { self.movingPromptID = nil }
                    )
                } else if let deletingCategoryID {
                    let categoryName = categories.first(where: { $0.id == deletingCategoryID })?.name ?? ""
                    AIPromptChoiceDialog(
                        title: String.localizedStringWithFormat(
                            String(
                                localized: "delete_category_confirm_title",
                                defaultValue: "Delete category \"%@\"?"
                            ),
                            categoryName
                        ),
                        choices: [false, true],
                        label: { deletePrompts in
                            deletePrompts
                                ? String(
                                    localized: "delete_category_and_prompts",
                                    defaultValue: "Delete category and its prompts"
                                )
                                : String(
                                    localized: "delete_category_keep_prompts",
                                    defaultValue: "Move prompts to root and delete category"
                                )
                        },
                        onSelect: { deleteCategory(deletePrompts: $0) },
                        onCancel: { self.deletingCategoryID = nil }
                    )
                } else if showingImportOptions {
                    AIPromptChoiceDialog(
                        title: String(localized: "import_prompts_csv", defaultValue: "Import prompts from CSV"),
                        choices: [false, true],
                        label: { installAsAddOn in
                            installAsAddOn
                                ? String(
                                    localized: "import_prompts_addon",
                                    defaultValue: "Install as add-on (read-only)"
                                )
                                : String(
                                    localized: "import_prompts_editable",
                                    defaultValue: "Import as editable prompts"
                                )
                        },
                        onSelect: { installAsAddOn in
                            showingImportOptions = false
                            promptImportMode = installAsAddOn ? .addOn : .editable
                            showingPromptImporter = true
                        },
                        onCancel: { showingImportOptions = false }
                    )
                } else if showingNewCategory {
                    AIPromptTextInputDialog(
                        title: String(localized: "new_category", defaultValue: "New category"),
                        hint: String(localized: "new_category_name", defaultValue: "Category name"),
                        text: $newCategoryName,
                        onSave: addCategory,
                        onCancel: { showingNewCategory = false }
                    )
                } else if renamingCategoryID != nil {
                    AIPromptTextInputDialog(
                        title: String(localized: "rename", defaultValue: "Rename"),
                        hint: String(localized: "new_category_name", defaultValue: "Category name"),
                        text: $categoryNameDraft,
                        onSave: renameCategory,
                        onCancel: { renamingCategoryID = nil }
                    )
                } else if showingResetConfirmation {
                    AIPromptConfirmationDialog(
                        title: String(
                            localized: "reset_all_ai_settings_confirm_title",
                            defaultValue: "Reset all AI settings?"
                        ),
                        message: String(
                            localized: "reset_all_ai_settings_confirm_message",
                            defaultValue: "This will clear the API key, provider, endpoint, model, and reset all prompts to defaults. Continue?"
                        ),
                        negativeTitle: String(localized: "cancel", defaultValue: "Cancel"),
                        positiveTitle: String(localized: "okay", defaultValue: "OK"),
                        onCancel: { showingResetConfirmation = false },
                        onConfirm: {
                            showingResetConfirmation = false
                            resetAllAISettings()
                        }
                    )
                } else if let deletingPromptID {
                    let promptName = entries.first(where: { $0.prompt.id == deletingPromptID })?.prompt.name ?? ""
                    AIPromptConfirmationDialog(
                        title: promptName,
                        message: String(
                            localized: "delete_prompt_confirm_message",
                            defaultValue: "Are you sure you want to delete this prompt?"
                        ),
                        negativeTitle: String(localized: "cancel", defaultValue: "Cancel"),
                        positiveTitle: String(localized: "okay", defaultValue: "OK"),
                        onCancel: { self.deletingPromptID = nil },
                        onConfirm: { deletePrompt(deletingPromptID) }
                    )
                }
            }
        }
    }

    /** Clears every prompt-owned dialog state without applying a pending mutation. */
    private func dismissPromptDialogs() {
        promptActionDialog = nil
        categoryActionDialog = nil
        movingPromptID = nil
        deletingCategoryID = nil
        showingImportOptions = false
        showingNewCategory = false
        renamingCategoryID = nil
        showingResetConfirmation = false
        deletingPromptID = nil
    }

    /** Routes one long-press prompt action and chains selection or confirmation dialogs as needed. */
    private func handlePromptAction(
        _ action: AIPromptRowAction,
        context: AIPromptActionDialogContext
    ) {
        promptActionDialog = nil
        switch action {
        case .hide:
            setBuiltInHidden(true, promptID: context.promptID)
        case .copy:
            copyPrompt(context.promptID)
        case .moveUp:
            movePrompt(context.promptID, offset: -1)
        case .moveDown:
            movePrompt(context.promptID, offset: 1)
        case .moveToCategory:
            movingPromptID = context.promptID
        case .delete:
            deletingPromptID = context.promptID
        }
    }

    /** Routes one long-press category action and chains name or deletion dialogs as needed. */
    private func handleCategoryAction(
        _ action: AIPromptCategoryAction,
        context: AIPromptCategoryDialogContext
    ) {
        categoryActionDialog = nil
        guard let category = categories.first(where: { $0.id == context.categoryID }) else { return }
        switch action {
        case .moveUp:
            moveCategory(context.categoryID, offset: -1)
        case .moveDown:
            moveCategory(context.categoryID, offset: 1)
        case .hide, .show:
            toggleCategoryHidden(category, isBuiltIn: context.isBuiltIn)
        case .rename:
            categoryNameDraft = context.categoryName
            renamingCategoryID = context.categoryID
        case .delete:
            deletingCategoryID = context.categoryID
        }
    }

    /** Builds one collapsible Android prompt group with category and prompt action controls. */
    @ViewBuilder
    private func promptSection(_ group: AIPromptManagementGroup) -> some View {
        VStack(spacing: 0) {
            promptSectionHeader(group)

            if !collapsedGroupIDs.contains(group.id) {
                ForEach(group.entries, id: \.prompt.id) { entry in
                    promptRow(entry)
                    Divider()
                        .overlay(surfacePalette.secondaryForegroundColor.opacity(0.24))
                }
            }
        }
    }

    /** Builds one expandable header, including Android's count, hidden styling, and category menu. */
    @ViewBuilder
    private func promptSectionHeader(_ group: AIPromptManagementGroup) -> some View {
        Button {
            if collapsedGroupIDs.contains(group.id) {
                collapsedGroupIDs.remove(group.id)
            } else {
                collapsedGroupIDs.insert(group.id)
            }
        } label: {
            HStack(spacing: 8) {
                AndBibleIconView(
                    name: collapsedGroupIDs.contains(group.id)
                        ? "PromptExpandIndicator"
                        : "PromptCollapseIndicator",
                    size: 20
                )
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                Text(groupTitle(group))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(surfacePalette.foregroundColor)
                Spacer(minLength: 8)
                Text(String(group.entries.count))
                    .font(.system(size: 14))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(surfacePalette.secondaryForegroundColor.opacity(0.09))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(groupAccessibilityIdentifier(group.id))
        .onLongPressGesture {
            guard let category = group.category else { return }
            categoryActionDialog = AIPromptCategoryDialogContext(
                categoryID: category.id,
                categoryName: category.name,
                isBuiltIn: group.isBuiltInCategory,
                actions: AIPromptDialogBehavior.categoryActions(
                    isBuiltIn: group.isBuiltInCategory,
                    isHidden: group.isHidden,
                    canMoveUp: categoryMoveTargetID(category.id, offset: -1) != nil,
                    canMoveDown: categoryMoveTargetID(category.id, offset: 1) != nil
                )
            )
        }
        .opacity(group.isHidden ? 0.5 : 1)
    }

    /** Returns Android's localized virtual/category title and hidden suffix. */
    private func groupTitle(_ group: AIPromptManagementGroup) -> String {
        let title: String
        switch group.id {
        case .favorites:
            title = String(localized: "prompt_category_favorites", defaultValue: "Favorites")
        case .uncategorized:
            title = String(localized: "prompt_category_uncategorized", defaultValue: "Uncategorized")
        case .category:
            title = group.category?.name ?? ""
        }
        guard group.isHidden else { return title }
        return "\(title) (\(String(localized: "ai_hidden_status", defaultValue: "hidden")))"
    }

    /** Returns a stable accessibility identifier for virtual and persisted group headers. */
    private func groupAccessibilityIdentifier(_ id: AIPromptManagementGroupID) -> String {
        switch id {
        case .favorites: return "aiPromptGroup::favorites"
        case .uncategorized: return "aiPromptGroup::uncategorized"
        case .category(let categoryID): return "aiPromptGroup::\(categoryID.uuidString)"
        }
    }

    /** Builds one prompt row while retaining source-aware editor and mutation behavior. */
    private func promptRow(_ entry: ResolvedAgentPrompt) -> some View {
        HStack(spacing: 8) {
            Button {
                openPrompt(entry.prompt.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.prompt.name)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(surfacePalette.foregroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if entry.origin == .builtIn {
                            Text(String(localized: "built_in_prompt", defaultValue: "Built-in"))
                                .font(.system(size: 13).italic())
                                .foregroundStyle(surfacePalette.controlAccentColor)
                        }
                    }

                    if case .swordPack(let moduleName) = entry.origin {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "addon_prompt_badge", defaultValue: "Add-on: %@"),
                                moduleName
                            )
                        )
                        .font(.system(size: 13).italic())
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        .lineLimit(1)
                    }

                    if let description = entry.prompt.promptDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 14))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(promptContextSummary(entry.prompt))
                        .font(.system(size: 13).italic())
                        .foregroundStyle(surfacePalette.secondaryForegroundColor.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                setFavorite(!favoriteIDs.contains(entry.prompt.id), promptID: entry.prompt.id)
            } label: {
                AndBibleIconView(
                    name: favoriteIDs.contains(entry.prompt.id)
                        ? "PromptFavoriteFilled"
                        : "PromptFavoriteOutline",
                    size: 24
                )
                .foregroundStyle(
                    favoriteIDs.contains(entry.prompt.id)
                        ? AndroidResourcePalette.promptFavoriteFilled
                        : AndroidResourcePalette.promptFavoriteOutline
                )
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "prompt_category_favorites", defaultValue: "Favorites"))
            .accessibilityAddTraits(favoriteIDs.contains(entry.prompt.id) ? .isSelected : [])
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onLongPressGesture {
            promptActionDialog = AIPromptActionDialogContext(
                promptID: entry.prompt.id,
                promptName: entry.prompt.name,
                actions: AIPromptDialogBehavior.promptActions(
                    origin: entry.origin,
                    canMoveUp: AIPromptManagementBehavior.siblingMoveTargetID(
                        promptID: entry.prompt.id,
                        offset: -1,
                        prompts: userPrompts
                    ) != nil,
                    canMoveDown: AIPromptManagementBehavior.siblingMoveTargetID(
                        promptID: entry.prompt.id,
                        offset: 1,
                        prompts: userPrompts
                    ) != nil
                )
            )
        }
    }

    /** Joins Android's localized `showIn` context names in enum order for one prompt row. */
    private func promptContextSummary(_ prompt: AgentPrompt) -> String {
        PromptContext.allCases
            .filter { prompt.showIn.contains($0) }
            .map(AIPromptPresentation.title(for:))
            .joined(separator: ", ")
    }

    /** Restores Android's initial expansion state: every group except hidden categories is open. */
    private func resetCollapsedGroups() {
        collapsedGroupIDs = Set(groups.filter(\.isHidden).map(\.id))
    }

    /** Inserts a user category from Android's toolbar dialog using the entity's default order. */
    private func addCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform {
            try settingsStore.insertCategory(PromptCategory(name: name))
            showingNewCategory = false
        }
    }

    /** Replaces one user category name after trimming dialog input. */
    private func renameCategory() {
        guard let renamingCategoryID else { return }
        let name = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform {
            guard let category = try settingsStore.userCategory(id: renamingCategoryID) else { return }
            category.name = name
            try settingsStore.save()
            self.renamingCategoryID = nil
        }
    }

    /** Deletes one user category using Android's selected prompt disposition. */
    private func deleteCategory(deletePrompts: Bool) {
        guard let deletingCategoryID else { return }
        perform {
            try settingsStore.deleteCategory(id: deletingCategoryID, deletePrompts: deletePrompts)
            self.deletingCategoryID = nil
        }
    }

    /** Returns the adjacent user-category identity for conditional up/down menu actions. */
    private func categoryMoveTargetID(_ categoryID: UUID, offset: Int) -> UUID? {
        guard let values = try? settingsStore.userCategories(),
              let sourceIndex = values.firstIndex(where: { $0.id == categoryID }) else {
            return nil
        }
        let targetIndex = sourceIndex + offset
        guard values.indices.contains(targetIndex) else { return nil }
        return values[targetIndex].id
    }

    /** Swaps adjacent user-category order values without persisting Android's code-owned categories. */
    private func moveCategory(_ categoryID: UUID, offset: Int) {
        perform {
            let values = try settingsStore.userCategories()
            guard let sourceIndex = values.firstIndex(where: { $0.id == categoryID }) else { return }
            let targetIndex = sourceIndex + offset
            guard values.indices.contains(targetIndex) else { return }
            let source = values[sourceIndex]
            let target = values[targetIndex]
            let sourceOrder = source.orderNumber
            source.orderNumber = target.orderNumber
            target.orderNumber = sourceOrder
            try settingsStore.save()
        }
    }

    /** Applies built-in global or user-row category visibility through its owning persistence path. */
    private func toggleCategoryHidden(_ category: PromptCategory, isBuiltIn: Bool) {
        perform {
            if isBuiltIn {
                let hidden = try repository.isCategoryHidden(category)
                try repository.setBuiltInCategoryHidden(!hidden, categoryID: category.id)
            } else if let managed = try settingsStore.userCategory(id: category.id) {
                managed.hidden.toggle()
                try settingsStore.save()
            }
        }
    }

    /** Persists one favorite state through the source-aware repository. */
    private func setFavorite(_ favorite: Bool, promptID: UUID) {
        perform { try repository.setFavorite(favorite, promptID: promptID) }
    }

    /** Persists built-in visibility without modifying code-owned prompt values. */
    private func setBuiltInHidden(_ hidden: Bool, promptID: UUID) {
        perform { try repository.setBuiltInPromptHidden(hidden, promptID: promptID) }
    }

    /** Copies any effective prompt into an editable user prompt. */
    private func copyPrompt(_ promptID: UUID) {
        perform { _ = try repository.copy(id: promptID) }
    }

    /** Deletes only an editable user prompt. */
    private func deletePrompt(_ promptID: UUID) {
        perform {
            try repository.delete(id: promptID)
            deletingPromptID = nil
        }
    }

    /** Moves one user prompt only among persisted siblings in its actual category. */
    private func movePrompt(_ promptID: UUID, offset: Int) {
        perform {
            let prompts = try settingsStore.userPrompts()
            guard AIPromptManagementBehavior.movePrompt(
                promptID: promptID,
                offset: offset,
                prompts: prompts
            ) else { return }
            try settingsStore.save()
        }
    }

    /** Moves one editable prompt to Android's selected category without changing editor routing. */
    private func movePrompt(_ promptID: UUID, toCategory categoryID: UUID?) {
        perform {
            guard let prompt = try settingsStore.userPrompt(id: promptID) else { return }
            prompt.categoryId = categoryID
            try settingsStore.save()
            movingPromptID = nil
        }
    }

    /** Clears only Android's hidden built-in prompt set and leaves category visibility unchanged. */
    private func restoreHiddenPrompts() {
        perform {
            let settings = try settingsStore.globalSettings()
            settings.hiddenBuiltInPrompts = []
            try settingsStore.save()
            noticeMessage = String(
                localized: "ai_prompts_restored",
                defaultValue: "Hidden prompts restored"
            )
        }
    }

    /** Encodes user prompts and opens the system destination picker, or reports Android's empty state. */
    private func preparePromptExport() {
        do {
            let prompts = try settingsStore.userPrompts()
            guard !prompts.isEmpty else {
                noticeMessage = String(
                    localized: "no_prompts_to_export",
                    defaultValue: "No user prompts to export"
                )
                return
            }
            promptExportDocument = AIPromptCSVTransferDocument(
                data: AIPromptCSVEncoder.encode(prompts: prompts, categories: categories)
            )
            showingPromptExporter = true
        } catch {
            failureMessage = String(
                format: String(localized: "csv_export_failed", defaultValue: "CSV export failed: %@"),
                error.localizedDescription
            )
        }
    }

    /** Converts the export picker's terminal result into Android-compatible completion feedback. */
    private func completePromptExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            let count = (try? settingsStore.userPrompts().count) ?? 0
            noticeMessage = String.localizedStringWithFormat(
                String(
                    localized: "prompts_csv_export_success",
                    defaultValue: "Exported %d prompts to CSV"
                ),
                count
            )
        case .failure(let error):
            failureMessage = String(
                format: String(localized: "csv_export_failed", defaultValue: "CSV export failed: %@"),
                error.localizedDescription
            )
        }
        promptExportDocument = nil
    }

    /** Timestamped Android-compatible filename supplied to the prompt CSV destination picker. */
    private var promptCSVFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "ai_prompts_\(formatter.string(from: Date())).csv"
    }

    /** Routes one selected CSV through editable import or the existing read-only add-on installer. */
    private func importPromptSelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            switch promptImportMode {
            case .editable:
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let summary = try importEditablePrompts(data: Data(contentsOf: url))
                noticeMessage = editableImportMessage(summary)
                refresh()
            case .addOn:
                let importResult = ExternalDocumentImportService.androidRegistryAware(
                    modelContext: modelContext,
                    swordManager: swordManager
                ).importDocument(
                    ExternalDocumentImportRequest(
                        url: url,
                        contentTypeIdentifier: UTType.commaSeparatedText.identifier,
                        suggestedFileName: url.lastPathComponent
                    )
                )
                if importResult.usesAndroidInstallToastFeedback {
                    noticeMessage = importResult.feedbackMessage
                    refresh()
                } else {
                    failureMessage = importResult.feedbackMessage
                }
            }
        } catch {
            failureMessage = String(
                format: String(localized: "csv_import_failed", defaultValue: "CSV import failed: %@"),
                error.localizedDescription
            )
        }
    }

    /**
     Imports shared-parser prompt values while resolving Android's category-name column.

     - Parameter data: User-selected semicolon CSV bytes.
     - Returns: Created, updated, and row-error counts.
     - Side effects: May insert categories and insert or update user prompts in SwiftData. Each valid
       row commits through existing stores, matching Android's partial-success import behavior.
     - Throws: Fatal UTF-8/header parsing errors; row ownership and persistence failures are counted.
     */
    private func importEditablePrompts(data: Data) throws -> AIPromptCSVImportSummary {
        let prompts = try PromptCSVParser.parse(data: data)
        let categoryNames = try AIPromptCSVCategoryMetadataDecoder.categoryNames(from: data)
        var categoryIDsByName: [String: UUID] = [:]
        for category in categories {
            categoryIDsByName[category.name] = category.id
        }

        var summary = AIPromptCSVImportSummary()
        for (index, prompt) in prompts.enumerated() {
            do {
                if categoryNames.indices.contains(index), let categoryName = categoryNames[index] {
                    if let categoryID = categoryIDsByName[categoryName] {
                        prompt.categoryId = categoryID
                    } else {
                        let category = PromptCategory(name: categoryName)
                        try settingsStore.insertCategory(category)
                        categoryIDsByName[categoryName] = category.id
                        prompt.categoryId = category.id
                    }
                }

                if let existing = try repository.entryById(prompt.id) {
                    guard existing.origin == .user else {
                        summary.errors += 1
                        continue
                    }
                    try repository.update(prompt)
                    summary.updated += 1
                } else {
                    try repository.insert(prompt)
                    summary.created += 1
                }
            } catch {
                summary.errors += 1
            }
        }
        return summary
    }

    /** Returns Android's success or partial-error summary for editable CSV import. */
    private func editableImportMessage(_ summary: AIPromptCSVImportSummary) -> String {
        if summary.errors > 0 {
            return String.localizedStringWithFormat(
                String(
                    localized: "csv_import_errors",
                    defaultValue: "Import completed with errors: %1$d created, %2$d updated, %3$d errors"
                ),
                summary.created,
                summary.updated,
                summary.errors
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "csv_import_success",
                defaultValue: "Import completed: %1$d created, %2$d updated"
            ),
            summary.created,
            summary.updated
        )
    }

    /** Executes Android's debug-only full AI reset through the existing credential-aware service. */
    private func resetAllAISettings() {
        guard let settingsRootCredentialStore else { return }
        do {
            try AISettingsResetter.reset(
                settingsStore: settingsStore,
                credentialStore: settingsRootCredentialStore
            )
            refresh()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Runs one prompt mutation and maps failures to shared credential-free UI text. */
    private func perform(_ mutation: () throws -> Void) {
        do {
            try mutation()
            refresh()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Invalidates category-grouped prompt snapshots after a mutation or child dismissal. */
    private func refresh() {
        revision &+= 1
    }
}

/** Prompt editor tab identity in Android's declared order. */
enum AIPromptEditorTab: String, CaseIterable, Identifiable {
    /// Basic prompt text, category, context, and routing controls.
    case prompt
    /// Per-prompt tool permission overrides.
    case permissions
    /// Model, cache, iteration, and execution controls.
    case advanced

    /// Stable SwiftUI identity.
    var id: String { rawValue }
}

/** Advanced prompt settings whose visibility changes for text transformations. */
enum AIPromptAdvancedField: String, CaseIterable, Equatable {
    /// Per-prompt configured-model override.
    case model
    /// Whether cached context must match exactly.
    case strictContextMatching
    /// Optional per-prompt iteration ceiling.
    case maxIterations
    /// Whether the task is edited before execution.
    case specifyBeforeRun
    /// Whether successful output skips document creation.
    case noDocumentCreation
    /// Whether installed documents are prefetched.
    case autoIncludeDocuments
    /// Whether commentaries are prefetched.
    case autoIncludeCommentaries
}

/** Optional per-prompt permission-mode selection. */
private enum AIPromptPermissionModeSelection: String, CaseIterable, Identifiable, Hashable {
    case inherited
    case alwaysAsk
    case askOncePerRun
    case allowAll
    case denyAll

    var id: String { rawValue }
}

/** Per-prompt tool availability override state. */
private enum AIPromptToolSelection: String, CaseIterable, Identifiable, Hashable {
    case inherited
    case allow
    case deny

    var id: String { rawValue }
}

/** Android prompt-editor toolbar commands in menu declaration order. */
enum AIPromptEditorToolbarAction: String, Equatable {
    /// Commits a user prompt or built-in model override.
    case save
    /// Confirms deletion of an existing user prompt.
    case delete
    /// Creates an editable copy of any existing prompt.
    case copyToCustomize
    /// Pushes Android's app-owned Tool Info destination.
    case availableTools
    /// Opens Android's prompt-editor help dialog.
    case help
}

/** Value snapshot of every prompt-editor draft field that can change before Save. */
struct AIPromptEditorDraftSnapshot: Equatable {
    /// Untrimmed prompt name shown in the editor.
    var name = ""
    /// Untrimmed optional description draft.
    var description = ""
    /// Prompt-template draft.
    var template = ""
    /// Selected action contexts.
    var contexts: Set<PromptContext> = []
    /// Selected category, or `nil` for Android's root group.
    var categoryID: UUID?
    /// Selected per-prompt model override.
    var modelID: UUID?
    /// Selected optional prompt permission mode.
    var permissionMode: AIPermissionMode?
    /// Explicitly allowed tools.
    var allowedTools: Set<AgentTool> = []
    /// Explicitly denied tools.
    var deniedTools: Set<AgentTool> = []
    /// Context-dependent cache selection.
    var strictContextMatching = true
    /// Whether the user supplies a task specification before execution.
    var specifyBeforeRun = false
    /// Whether document output is disabled.
    var noDocumentCreation = false
    /// Optional maximum-iteration text draft.
    var maxIterations = ""
    /// Whether installed documents are automatically included.
    var autoIncludeDocuments = false
    /// Whether commentaries are automatically included.
    var autoIncludeCommentaries = false
    /// Whether the prompt is limited to Bible documents.
    var bibleOnly = false
    /// Whether the prompt transforms selected text.
    var isTextTransformation = false
}

/** Pure Android visibility and dirty-state rules shared by the editor and focused tests. */
enum AIPromptEditorBehavior {
    /**
     Resolves `PromptEditActivity.onPrepareOptionsMenu()` for the loaded source state.

     - Parameters:
       - origin: Effective prompt ownership.
       - promptID: Existing identity, or `nil` for a new user prompt.
       - isLoaded: Whether asynchronous source resolution has completed.
     - Returns: Android-ordered visible toolbar actions.
     - Side effects: None.
     - Failure modes: None.
     */
    static func toolbarActions(
        origin: PromptOrigin,
        promptID: UUID?,
        isLoaded: Bool
    ) -> [AIPromptEditorToolbarAction] {
        guard isLoaded else { return [] }
        let isExisting = promptID != nil
        var actions: [AIPromptEditorToolbarAction] = []
        if origin == .user || origin == .builtIn {
            actions.append(.save)
        }
        if origin == .user, isExisting {
            actions.append(.delete)
        }
        if isExisting {
            actions.append(.copyToCustomize)
        }
        actions.append(.availableTools)
        actions.append(.help)
        return actions
    }

    /**
     Compares the current draft with the captured load snapshot using Android source ownership.

     Built-in prompts only expose the model override, add-on prompts are fully read-only, and user
     prompts compare every drafted field. This function performs no persistence.
     */
    static func isDirty(
        origin: PromptOrigin,
        initial: AIPromptEditorDraftSnapshot?,
        current: AIPromptEditorDraftSnapshot
    ) -> Bool {
        guard let initial else { return false }
        switch origin {
        case .builtIn:
            return initial.modelID != current.modelID
        case .swordPack:
            return false
        case .user:
            return initial != current
        }
    }

    /**
     Resolves Android's visible tabs after applying text-transformation mode.

     - Parameter isTextTransformation: Whether the prompt directly transforms selected text.
     - Returns: Prompt and Advanced for transformations; otherwise all three tabs.
     - Side effects: None. The result is deterministic.
     - Failure modes: None.
     */
    static func visibleTabs(isTextTransformation: Bool) -> [AIPromptEditorTab] {
        isTextTransformation ? [.prompt, .advanced] : AIPromptEditorTab.allCases
    }

    /**
     Applies Android's Bible-only context restriction.

     - Parameters:
       - contexts: Draft contexts selected by the user or loaded from persistence.
       - bibleOnly: Whether the prompt is restricted to Bible documents.
     - Returns: The supplied set without Workspace or Note Editor when Bible-only is enabled.
     - Side effects: None. The result is deterministic.
     - Failure modes: None.
     */
    static func normalizedContexts(
        _ contexts: Set<PromptContext>,
        bibleOnly: Bool
    ) -> Set<PromptContext> {
        guard bibleOnly else { return contexts }
        return contexts.subtracting([.workspaceMenu, .noteEditor])
    }

    /**
     Resolves the Advanced rows Android keeps for a text-transformation prompt.

     - Parameter isTextTransformation: Whether the prompt directly transforms selected text.
     - Returns: Android-ordered visible Advanced fields.
     - Side effects: None. The result is deterministic.
     - Failure modes: None.
     */
    static func visibleAdvancedFields(
        isTextTransformation: Bool
    ) -> [AIPromptAdvancedField] {
        var fields: [AIPromptAdvancedField] = [.model, .strictContextMatching]
        if !isTextTransformation {
            fields.append(.maxIterations)
        }
        fields.append(.specifyBeforeRun)
        if !isTextTransformation {
            fields.append(contentsOf: [
                .noDocumentCreation,
                .autoIncludeDocuments,
                .autoIncludeCommentaries,
            ])
        }
        return fields
    }
}

/**
 Full source-aware prompt editor used by settings and generated-document source links.

 All controls write only local SwiftUI draft state. Save is the sole persistence boundary, including
 built-in model overrides; custom Back navigation confirms before discarding a dirty draft.
 */
private enum AIPromptEditorModal: Identifiable {
    /// Category Spinner replacement.
    case category
    /// Permission-mode Spinner replacement.
    case permissionMode
    /// Per-tool radio choice replacement.
    case tool(AgentTool)
    /// Advanced model ListPreference replacement.
    case model
    /// Advanced max-iterations EditTextPreference replacement.
    case maxIterations

    var id: String {
        switch self {
        case .category: return "category"
        case .permissionMode: return "permissionMode"
        case .tool(let tool): return "tool::\(tool.rawValue)"
        case .model: return "model"
        case .maxIterations: return "maxIterations"
        }
    }
}

struct AIPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext

    /// Active prompt identity; copying replaces this with the editable copy just as Android does.
    @State private var promptID: UUID?
    let swordManager: SwordManager?
    /// Reader/workspace palette inherited from the owning activity.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command, or nil for the environment fallback.
    let onBack: (() -> Void)?
    let onChanged: () -> Void

    @State private var selectedTab = AIPromptEditorTab.prompt
    @State private var origin = PromptOrigin.user
    @State private var name = ""
    @State private var description = ""
    @State private var template = ""
    @State private var contexts: Set<PromptContext> = []
    @State private var categoryID: UUID?
    @State private var modelID: UUID?
    @State private var permissionMode = AIPromptPermissionModeSelection.inherited
    @State private var allowedTools: Set<AgentTool> = []
    @State private var deniedTools: Set<AgentTool> = []
    @State private var strictContextMatching = true
    @State private var specifyBeforeRun = false
    @State private var noDocumentCreation = false
    @State private var maxIterations = ""
    @State private var autoIncludeDocuments = false
    @State private var autoIncludeCommentaries = false
    @State private var bibleOnly = false
    @State private var isTextTransformation = false
    @State private var orderNumber = 0
    @State private var createdAtMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    @State private var loaded = false
    /// Immutable draft captured after the source prompt finishes loading.
    @State private var initialSnapshot: AIPromptEditorDraftSnapshot?
    /// Whether Android's message-only discard confirmation blocks the editor.
    @State private var showingDiscardConfirmation = false
    /// Whether Android's existing-user prompt deletion confirmation blocks the editor.
    @State private var showingDeleteConfirmation = false
    /// Android's app-owned prompt-editor Help dialog.
    @State private var helpDialog: AIConfigurationDialog?
    @State private var failureMessage: String?
    /// Android-equivalent transient feedback for validation and successful copy operations.
    @State private var toastMessage: String?
    /// App-owned Spinner/ListPreference dialog currently replacing an editor selection control.
    @State private var activeModal: AIPromptEditorModal?
    /// Whether the Available tools activity locally replaces the editor.
    @State private var showsAvailableTools = false
    /// Whether Android's `SHOW_AS_ACTION_NEVER` overflow popup is visible.
    @State private var showsOverflowMenu = false
    /// Tool category identities manually collapsed in the Permissions tab.
    @State private var collapsedPermissionCategoryIDs: Set<String> = []

    /**
     Creates an editor whose active source can be replaced after Copy to customize.

     - Parameters:
       - promptID: Existing source identity, or `nil` for a new user prompt.
       - swordManager: Optional SWORD prompt-pack provider.
       - surfacePalette: Palette inherited from the reader/workspace owner.
       - onBack: Explicit Android Up command, or nil for standalone dismissal.
       - onChanged: Callback invoked after successful persistence changes.
     - Side effects: None until the view loads or the user performs an action.
     - Failure modes: Loading and mutation failures are presented inside the editor.
     */
    init(
        promptID: UUID?,
        swordManager: SwordManager?,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil,
        onChanged: @escaping () -> Void
    ) {
        _promptID = State(initialValue: promptID)
        self.swordManager = swordManager
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onChanged = onChanged
    }

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    private var repository: PromptRepository {
        PromptRepository(
            settingsStore: settingsStore,
            packProvider: swordManager.map { SwordPromptPackProvider(swordManager: $0) }
        )
    }
    private var categories: [PromptCategory] { (try? repository.allCategories()) ?? [] }
    private var models: [LLMConfiguredModel] { (try? settingsStore.allModels()) ?? [] }
    private var isReadOnly: Bool { origin != .user }
    /// Android's current tab list after text-transformation filtering.
    private var visibleTabs: [AIPromptEditorTab] {
        AIPromptEditorBehavior.visibleTabs(isTextTransformation: isTextTransformation)
    }
    /// Android's current Advanced-row list after text-transformation filtering.
    private var visibleAdvancedFields: [AIPromptAdvancedField] {
        AIPromptEditorBehavior.visibleAdvancedFields(
            isTextTransformation: isTextTransformation
        )
    }
    /// Android-ordered actions visible for the current loaded source state.
    private var toolbarActions: [AIPromptEditorToolbarAction] {
        AIPromptEditorBehavior.toolbarActions(origin: origin, promptID: promptID, isLoaded: loaded)
    }

    /// Whether an Android editor dialog currently owns content and toolbar interaction.
    private var isEditorDialogPresented: Bool {
        showingDiscardConfirmation
            || showingDeleteConfirmation
            || helpDialog != nil
            || activeModal != nil
    }

    /// Current value snapshot used only for dirty comparison until explicit Save.
    private var currentSnapshot: AIPromptEditorDraftSnapshot {
        AIPromptEditorDraftSnapshot(
            name: name,
            description: description,
            template: template,
            contexts: contexts,
            categoryID: categoryID,
            modelID: modelID,
            permissionMode: AIPromptPresentation.mode(for: permissionMode),
            allowedTools: allowedTools,
            deniedTools: deniedTools,
            strictContextMatching: strictContextMatching,
            specifyBeforeRun: specifyBeforeRun,
            noDocumentCreation: noDocumentCreation,
            maxIterations: maxIterations,
            autoIncludeDocuments: autoIncludeDocuments,
            autoIncludeCommentaries: autoIncludeCommentaries,
            bibleOnly: bibleOnly,
            isTextTransformation: isTextTransformation
        )
    }

    /// Whether Back must ask before discarding local draft changes.
    private var isDirty: Bool {
        AIPromptEditorBehavior.isDirty(
            origin: origin,
            initial: initialSnapshot,
            current: currentSnapshot
        )
    }

    /** Trims optional descriptive copy before it crosses the persistence boundary. */
    private var normalizedDescription: String? {
        let value = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        Group {
            if showsAvailableTools {
                AIPromptToolInfoView(
                    surfacePalette: surfacePalette,
                    onBack: { showsAvailableTools = false }
                )
            } else {
                promptEditorActivity
            }
        }
        .task {
            guard !loaded else { return }
            load()
            await Task.yield()
            if loaded { initialSnapshot = currentSnapshot }
        }
        .onChange(of: bibleOnly) { _, enabled in
            contexts = AIPromptEditorBehavior.normalizedContexts(
                contexts,
                bibleOnly: enabled
            )
        }
        .onChange(of: isTextTransformation) { _, enabled in
            if enabled, selectedTab == .permissions {
                selectedTab = .prompt
            }
        }
        .androidToastFeedback(toastMessage)
        .aiConfigurationDialog($helpDialog, credentialStore: .keychain())
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Full app-owned PromptEditActivity using Android's exact action order and fixed tabs. */
    private var promptEditorActivity: some View {
        ZStack {
            AndroidActivityScreen(
                title: editorTitle,
                accessibilityIdentifier: "aiPromptEditorTopAppBar",
                palette: surfacePalette,
                onBack: requestClose
            ) {
                if toolbarActions.contains(.save) {
                    editorActionButton(
                        icon: "ActivitySave",
                        label: String(localized: "okay", defaultValue: "OK"),
                        identifier: "aiPromptEditorSaveButton",
                        action: validateAndSave
                    )
                }
                if toolbarActions.contains(.delete) {
                    editorActionButton(
                        icon: "ActivityDelete",
                        label: String(localized: "delete", defaultValue: "Delete"),
                        identifier: "aiPromptEditorDeleteButton"
                    ) {
                        showingDeleteConfirmation = true
                    }
                }
                if toolbarActions.contains(.copyToCustomize) {
                    editorActionButton(
                        icon: "ActivityCopy",
                        label: String(localized: "copy_to_customize", defaultValue: "Copy to customize"),
                        identifier: "aiPromptEditorCopyButton",
                        action: copyToCustomize
                    )
                }
                if toolbarActions.contains(.help) {
                    editorActionButton(
                        icon: "ActivityHelp",
                        label: String(localized: "help", defaultValue: "Help"),
                        identifier: "aiPromptEditorHelpButton",
                        action: showHelp
                    )
                }
                if toolbarActions.contains(.availableTools) {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("ToolbarOverflow"),
                        accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                        accessibilityIdentifier: "aiPromptEditorOverflowButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor
                    ) {
                        showsOverflowMenu.toggle()
                    }
                    .androidPopupMenuAnchor(id: "aiPromptEditorOverflowAnchor")
                }
            } content: {
                VStack(spacing: 0) {
                    if isReadOnly {
                        HStack(alignment: .top, spacing: 8) {
                            AndBibleIconView(name: "DocumentLock", size: 20)
                                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            Text(readOnlyNotice)
                                .font(.system(size: 14))
                                .foregroundStyle(surfacePalette.foregroundColor)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(surfacePalette.secondaryForegroundColor.opacity(0.12))
                    }

                    AndroidFixedTabRow(
                        items: visibleTabs.map {
                            AndroidFixedTabItem(
                                id: $0.rawValue,
                                value: $0,
                                title: tabTitle($0)
                            )
                        },
                        selection: $selectedTab,
                        backgroundColor: surfacePalette.backgroundColor,
                        foregroundColor: surfacePalette.foregroundColor,
                        secondaryForegroundColor: surfacePalette.secondaryForegroundColor,
                        accentColor: surfacePalette.controlAccentColor
                    )

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch selectedTab {
                            case .prompt: promptFields
                            case .permissions: permissionFields
                            case .advanced: advancedFields
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .accessibilityHidden(isEditorDialogPresented)
            .disabled(isEditorDialogPresented)

            editorModalOverlay
        }
        .androidAnchoredPopupMenu(
            anchorID: "aiPromptEditorOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: 52,
            accessibilityIdentifier: "aiPromptEditorOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiPromptEditorOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                AndroidPopupMenuRow(
                    title: String(localized: "ai_available_tools", defaultValue: "Available tools"),
                    icon: .asset("ActivityInfo"),
                    accessibilityIdentifier: "aiPromptEditorToolsButton"
                ) {
                    showsOverflowMenu = false
                    showsAvailableTools = true
                }
            }
        }
    }

    /** Creates one exact-asset action in Android's prompt editor app bar. */
    private func editorActionButton(
        icon: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidActivityTopAppBarActionButton(
            icon: .asset(icon),
            accessibilityLabel: label,
            accessibilityIdentifier: identifier,
            foregroundColor: surfacePalette.toolbarForegroundColor,
            action: action
        )
    }

    /** Presents the highest-priority app-owned editor confirmation or selection dialog. */
    @ViewBuilder
    private var editorModalOverlay: some View {
        if showingDiscardConfirmation {
            AIPromptDialogOverlay(onDismiss: { showingDiscardConfirmation = false }) {
                AIPromptConfirmationDialog(
                    title: nil,
                    message: String(
                        localized: "discard_changes_confirmation",
                        defaultValue: "Discard unsaved changes?"
                    ),
                    negativeTitle: String(localized: "no", defaultValue: "No"),
                    positiveTitle: String(localized: "yes", defaultValue: "Yes"),
                    onCancel: { showingDiscardConfirmation = false },
                    onConfirm: performDismiss
                )
            }
        } else if showingDeleteConfirmation {
            AIPromptDialogOverlay(onDismiss: { showingDeleteConfirmation = false }) {
                AIPromptConfirmationDialog(
                    title: nil,
                    message: String.localizedStringWithFormat(
                        String(
                            localized: "delete_prompt_confirmation",
                            defaultValue: "Delete prompt \"%@\"?"
                        ),
                        name
                    ),
                    negativeTitle: String(localized: "no", defaultValue: "No"),
                    positiveTitle: String(localized: "yes", defaultValue: "Yes"),
                    onCancel: { showingDeleteConfirmation = false },
                    onConfirm: deleteAndClose
                )
            }
        } else if let activeModal {
            promptSelectionDialog(activeModal)
        }
    }

    /** Builds the app-owned choice or EditTextPreference dialog represented by editor state. */
    @ViewBuilder
    private func promptSelectionDialog(_ modal: AIPromptEditorModal) -> some View {
        switch modal {
        case .category:
            AndroidSingleChoiceDialog(
                title: String(localized: "prompt_category", defaultValue: "Category"),
                selectedValue: categoryID,
                options: [
                    AndroidSingleChoiceOption(
                        id: "none",
                        value: UUID?.none,
                        title: String(localized: "category_none", defaultValue: "No category")
                    ),
                ] + categories.map {
                    AndroidSingleChoiceOption(id: $0.id.uuidString, value: Optional($0.id), title: $0.name)
                },
                accessibilityIdentifier: "aiPromptCategoryDialog",
                onSelect: {
                    categoryID = $0
                    activeModal = nil
                },
                onCancel: { activeModal = nil }
            )
        case .permissionMode:
            AndroidSingleChoiceDialog(
                title: String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
                selectedValue: permissionMode,
                options: AIPromptPermissionModeSelection.allCases.map {
                    AndroidSingleChoiceOption(
                        id: $0.rawValue,
                        value: $0,
                        title: permissionModeTitle($0)
                    )
                },
                accessibilityIdentifier: "aiPromptPermissionModeDialog",
                onSelect: {
                    permissionMode = $0
                    activeModal = nil
                },
                onCancel: { activeModal = nil }
            )
        case .tool(let tool):
            AndroidSingleChoiceDialog(
                title: AIPermissionPresentation.title(for: tool),
                selectedValue: toolBinding(tool).wrappedValue,
                options: AIPromptToolSelection.allCases.map {
                    AndroidSingleChoiceOption(
                        id: $0.rawValue,
                        value: $0,
                        title: toolPermissionTitle($0, tool: tool)
                    )
                },
                accessibilityIdentifier: "aiPromptToolDialog::\(tool.rawValue)",
                onSelect: {
                    toolBinding(tool).wrappedValue = $0
                    activeModal = nil
                },
                onCancel: { activeModal = nil }
            )
        case .model:
            AndroidSingleChoiceDialog(
                title: String(localized: "prompt_model_override", defaultValue: "Model"),
                selectedValue: modelID,
                options: [
                    AndroidSingleChoiceOption(
                        id: "default",
                        value: UUID?.none,
                        title: String(localized: "prompt_model_default", defaultValue: "Default")
                    ),
                ] + models.map {
                    AndroidSingleChoiceOption(id: $0.id.uuidString, value: Optional($0.id), title: $0.modelId)
                },
                accessibilityIdentifier: "aiPromptModelDialog",
                onSelect: {
                    modelID = $0
                    activeModal = nil
                },
                onCancel: { activeModal = nil }
            )
        case .maxIterations:
            AndroidEditTextPreferenceDialog(
                title: String(localized: "prompt_max_iterations", defaultValue: "Max iterations override"),
                initialText: maxIterations,
                placeholder: String(
                    localized: "prompt_max_iterations_hint",
                    defaultValue: "Leave empty for global default"
                ),
                accessibilityIdentifier: "aiPromptMaxIterationsDialog",
                validator: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty || (Int(trimmed).map { $0 >= 0 } ?? false) else {
                        return String(localized: "error_occurred", defaultValue: "An error has occurred")
                    }
                    return nil
                },
                onCancel: { activeModal = nil },
                onSave: {
                    maxIterations = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    activeModal = nil
                }
            )
        }
    }

    /// Current category label shown by Android's category Spinner trigger.
    private var selectedCategoryTitle: String {
        guard let categoryID else {
            return String(localized: "category_none", defaultValue: "No category")
        }
        return categories.first(where: { $0.id == categoryID })?.name
            ?? String(localized: "category_none", defaultValue: "No category")
    }

    /// Current model label shown by Android's Advanced ListPreference row.
    private var selectedModelTitle: String {
        guard let modelID else {
            return String(localized: "prompt_model_default", defaultValue: "Default")
        }
        return models.first(where: { $0.id == modelID })?.modelId
            ?? String(localized: "prompt_model_default", defaultValue: "Default")
    }

    /** Returns Android's localized label for one optional prompt permission mode. */
    private func permissionModeTitle(_ mode: AIPromptPermissionModeSelection) -> String {
        switch mode {
        case .inherited:
            return String(localized: "prompt_permission_use_default", defaultValue: "Use default")
        case .alwaysAsk:
            return String(localized: "permission_always_ask", defaultValue: "Always ask")
        case .askOncePerRun:
            return String(localized: "permission_ask_once_per_run", defaultValue: "Ask once per run")
        case .allowAll:
            return String(localized: "permission_allow_all", defaultValue: "Allow all")
        case .denyAll:
            return String(localized: "permission_deny_all", defaultValue: "Deny all")
        }
    }

    /** Returns the Android radio label for one per-tool override value. */
    private func toolPermissionTitle(
        _ selection: AIPromptToolSelection,
        tool: AgentTool
    ) -> String {
        switch selection {
        case .inherited:
            return defaultToolPermissionTitle(tool)
        case .allow:
            return tool.access == .write
                ? String(localized: "permission_option_always_allow", defaultValue: "Always allow")
                : String(localized: "tool_option_enabled", defaultValue: "Enabled")
        case .deny:
            return tool.access == .write
                ? String(localized: "permission_option_always_deny", defaultValue: "Always deny")
                : String(localized: "tool_option_disabled", defaultValue: "Disabled")
        }
    }

    /** Returns from the editor through its explicit owner or standalone environment fallback. */
    private func performDismiss() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /** Returns Android's localized label for one visible editor tab. */
    private func tabTitle(_ tab: AIPromptEditorTab) -> String {
        switch tab {
        case .prompt:
            return String(localized: "prompt_tab_prompt", defaultValue: "Prompt")
        case .permissions:
            return String(localized: "prompt_tab_permissions", defaultValue: "Permissions")
        case .advanced:
            return String(localized: "prompt_tab_advanced", defaultValue: "Advanced")
        }
    }

    /// Android activity title for new, built-in, add-on, and editable prompt sources.
    private var editorTitle: String {
        guard promptID != nil else {
            return String(localized: "new_prompt", defaultValue: "New prompt")
        }
        switch origin {
        case .builtIn:
            return String(localized: "built_in_prompt", defaultValue: "Built-in")
        case .swordPack(let moduleName):
            return String.localizedStringWithFormat(
                String(localized: "addon_prompt_badge", defaultValue: "Add-on: %@"),
                moduleName
            )
        case .user:
            return String(localized: "edit_prompt", defaultValue: "Edit prompt")
        }
    }

    /// Android source-specific notice shown above read-only prompt fields.
    private var readOnlyNotice: String {
        switch origin {
        case .swordPack(let moduleName):
            return String.localizedStringWithFormat(
                String(
                    localized: "addon_prompt_notice",
                    defaultValue: "This prompt is from add-on module \"%@\" and cannot be edited. Use \"Copy to customize\" to create an editable copy."
                ),
                moduleName
            )
        case .builtIn, .user:
            return String(
                localized: "built_in_prompt_notice",
                defaultValue: "This is a built-in prompt and cannot be edited. Use \"Copy to customize\" to create an editable copy."
            )
        }
    }

    /** Main prompt text, context, category, and model fields. */
    @ViewBuilder
    private var promptFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            promptTextField(
                title: String(localized: "prompt_name", defaultValue: "Name"),
                text: $name,
                identifier: "aiPromptNameField"
            )
            promptTextField(
                title: String(localized: "prompt_description", defaultValue: "Description"),
                text: $description,
                identifier: "aiPromptDescriptionField"
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "prompt_template", defaultValue: "Prompt template"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(surfacePalette.foregroundColor)
                TextEditor(text: $template)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16))
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(surfacePalette.secondaryForegroundColor.opacity(0.08))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(surfacePalette.inactiveBorderColor)
                            .frame(height: 1)
                    }
                    .disabled(isReadOnly)
                    .opacity(isReadOnly ? 0.45 : 1)
                    .accessibilityIdentifier("aiPromptTemplateField")
            }

            AndroidSelectionField(
                title: String(localized: "prompt_category", defaultValue: "Category"),
                value: selectedCategoryTitle,
                isEnabled: !isReadOnly,
                palette: surfacePalette,
                accessibilityIdentifier: "aiPromptCategoryField"
            ) {
                activeModal = .category
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "prompt_show_in", defaultValue: "Show in"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(surfacePalette.foregroundColor)
                .padding(.top, 8)

            AndroidCheckboxRow(
                title: String(localized: "prompt_bible_only", defaultValue: "Bible documents only"),
                isOn: $bibleOnly,
                isEnabled: !isReadOnly,
                foregroundColor: surfacePalette.foregroundColor,
                accentColor: surfacePalette.controlAccentColor,
                accessibilityIdentifier: "aiPromptBibleOnlyCheckbox"
            )
            ForEach(PromptContext.allCases, id: \.self) { context in
                AndroidCheckboxRow(
                    title: AIPromptPresentation.title(for: context),
                    isOn: contextBinding(context),
                    isEnabled: !isReadOnly
                        && !(bibleOnly && (context == .workspaceMenu || context == .noteEditor)),
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    accessibilityIdentifier: "aiPromptContext::\(context.rawValue)"
                )
            }

            AndroidCheckboxRow(
                title: String(localized: "prompt_is_text_transformation", defaultValue: "Text transformation"),
                isOn: $isTextTransformation,
                isEnabled: !isReadOnly,
                foregroundColor: surfacePalette.foregroundColor,
                accentColor: surfacePalette.controlAccentColor,
                accessibilityIdentifier: "aiPromptTextTransformationCheckbox"
            )
            Text(
                String(
                    localized: "prompt_is_text_transformation_description",
                    defaultValue: "Uses a simplified system prompt that preserves formatting (links, headings, bold/italic) while transforming text content. No tools are used. Ideal for translation and editing prompts."
                )
            )
            .font(.system(size: 13))
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .padding(.leading, 32)
        }
    }

    /** Renders one labeled AppCompat single-line prompt editor field. */
    @ViewBuilder
    private func promptTextField(
        title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(surfacePalette.foregroundColor)
            AndroidActivityTextInput(
                placeholder: "",
                text: text,
                foregroundColor: surfacePalette.foregroundColor,
                backgroundColor: surfacePalette.secondaryForegroundColor.opacity(0.08),
                borderColor: surfacePalette.inactiveBorderColor,
                accessibilityIdentifier: identifier
            )
        }
        .disabled(isReadOnly)
        .opacity(isReadOnly ? 0.45 : 1)
    }

    /** Per-prompt mode and complete allowed/denied tool controls. */
    @ViewBuilder
    private var permissionFields: some View {
        AndroidSelectionField(
            title: String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
            value: permissionModeTitle(permissionMode),
            summary: String(
                localized: "prompt_permission_mode_description",
                defaultValue: "Controls when user confirmation is required before the AI performs write operations. The per-tool settings below can override this for individual tools."
            ),
            isEnabled: !isReadOnly,
            palette: surfacePalette,
            accessibilityIdentifier: "aiPromptPermissionModeField"
        ) {
            activeModal = .permissionMode
        }

        ForEach(AIPermissionPresentation.categories, id: \.category.rawValue) { group in
            promptPermissionCategory(group)
        }

        if !isReadOnly {
            AndroidRaisedTextButton(
                title: String(localized: "reset_all_permissions", defaultValue: "Reset all"),
                foregroundColor: surfacePalette.controlAccentColor,
                backgroundColor: surfacePalette.secondaryForegroundColor.opacity(0.08),
                accessibilityIdentifier: "aiPromptResetPermissionsButton"
            ) {
                    allowedTools.removeAll()
                    deniedTools.removeAll()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /** Builds Android's expandable permission category with read/write aggregate checkboxes. */
    private func promptPermissionCategory(
        _ group: AIPermissionPresentation.CategoryGroup
    ) -> some View {
        let categoryID = group.category.rawValue
        let readTools = group.tools.filter { $0.access != .write }
        let writeTools = group.tools.filter { $0.access == .write }
        let isCollapsed = collapsedPermissionCategoryIDs.contains(categoryID)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isCollapsed {
                        collapsedPermissionCategoryIDs.remove(categoryID)
                    } else {
                        collapsedPermissionCategoryIDs.insert(categoryID)
                    }
                } label: {
                    HStack(spacing: 8) {
                        AndBibleIconView(
                            name: isCollapsed ? "PromptExpandIndicator" : "PromptCollapseIndicator",
                            size: 24
                        )
                        .foregroundStyle(surfacePalette.secondaryForegroundColor)
                        Text(group.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(surfacePalette.foregroundColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                if !readTools.isEmpty {
                    permissionGroupToggle(
                        title: String(localized: "tool_category_read", defaultValue: "Read"),
                        tools: readTools,
                        categoryID: categoryID,
                        identifier: "read"
                    )
                }
                if !writeTools.isEmpty {
                    permissionGroupToggle(
                        title: String(localized: "tool_category_write", defaultValue: "Write"),
                        tools: writeTools,
                        categoryID: categoryID,
                        identifier: "write"
                    )
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 4)

            if !isCollapsed {
                ForEach(group.tools, id: \.self) { tool in
                    promptToolPermissionRow(tool)
                }
            }
        }
        .accessibilityIdentifier("aiPromptPermissionCategory::\(categoryID)")
    }

    /** Creates Android's compact category checkbox that resets or denies a complete tool subset. */
    private func permissionGroupToggle(
        title: String,
        tools: [AgentTool],
        categoryID: String,
        identifier: String
    ) -> some View {
        let isOn = tools.allSatisfy { !deniedTools.contains($0) }
        return Button {
            setPermissionGroup(to: !isOn, tools: tools, categoryID: categoryID)
        } label: {
            HStack(spacing: 2) {
                AndroidCheckboxIndicator(
                    isOn: isOn,
                    uncheckedColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor
                )
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(surfacePalette.foregroundColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
        .opacity(isReadOnly ? 0.45 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(
            isOn
                ? String(localized: "tool_option_enabled", defaultValue: "Enabled")
                : String(localized: "tool_option_disabled", defaultValue: "Disabled")
        )
        .accessibilityIdentifier("aiPromptPermissionCategory::\(categoryID)::\(identifier)")
    }

    /** Renders one Android horizontal three-state tool permission radio group. */
    private func promptToolPermissionRow(_ tool: AgentTool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(AIPermissionPresentation.title(for: tool))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(surfacePalette.foregroundColor)

            HStack(alignment: .top, spacing: 8) {
                AndroidInlineRadioOption(
                    title: defaultToolPermissionTitle(tool),
                    value: AIPromptToolSelection.inherited,
                    selection: toolBinding(tool),
                    isEnabled: !isReadOnly,
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    accessibilityIdentifier: "aiPromptTool::\(tool.rawValue)::default"
                )
                AndroidInlineRadioOption(
                    title: tool.access == .write
                        ? String(localized: "permission_option_always_allow", defaultValue: "Always allow")
                        : String(localized: "tool_option_enabled", defaultValue: "Enabled"),
                    value: AIPromptToolSelection.allow,
                    selection: toolBinding(tool),
                    isEnabled: !isReadOnly,
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    accessibilityIdentifier: "aiPromptTool::\(tool.rawValue)::allow"
                )
                AndroidInlineRadioOption(
                    title: tool.access == .write
                        ? String(localized: "permission_option_always_deny", defaultValue: "Always deny")
                        : String(localized: "tool_option_disabled", defaultValue: "Disabled"),
                    value: AIPromptToolSelection.deny,
                    selection: toolBinding(tool),
                    isEnabled: !isReadOnly,
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    accessibilityIdentifier: "aiPromptTool::\(tool.rawValue)::deny"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /** Applies Android's aggregate toggle rule and automatic expand/collapse behavior. */
    private func setPermissionGroup(
        to enabled: Bool,
        tools: [AgentTool],
        categoryID: String
    ) {
        for tool in tools {
            allowedTools.remove(tool)
            if enabled {
                deniedTools.remove(tool)
            } else {
                deniedTools.insert(tool)
            }
        }

        let categoryTools = AIPermissionPresentation.categories
            .first(where: { $0.category.rawValue == categoryID })?.tools ?? []
        if categoryTools.allSatisfy({ deniedTools.contains($0) }) {
            collapsedPermissionCategoryIDs.insert(categoryID)
        } else {
            collapsedPermissionCategoryIDs.remove(categoryID)
        }
    }

    /** Resolves Android's globally qualified Default label for one prompt tool. */
    private func defaultToolPermissionTitle(_ tool: AgentTool) -> String {
        let settings = try? settingsStore.globalSettings()
        if tool.access != .write {
            return (settings?.permanentlyDeniedTools ?? []).contains(tool)
                ? String(localized: "tool_option_default_disabled", defaultValue: "Default (disabled)")
                : String(localized: "tool_option_default_enabled", defaultValue: "Default (enabled)")
        }
        if (settings?.permanentlyAllowedTools ?? []).contains(tool) {
            return String(localized: "tool_option_default_allowed", defaultValue: "Default (allowed)")
        }
        if (settings?.permanentlyDeniedTools ?? []).contains(tool) {
            return String(localized: "tool_option_default_denied", defaultValue: "Default (denied)")
        }
        return String(localized: "permission_status_default", defaultValue: "Ask (default)")
    }

    /** Iteration, cache, context prefetch, and result-routing fields. */
    @ViewBuilder
    private var advancedFields: some View {
        AndroidPreferenceSection(palette: surfacePalette) {
            ForEach(visibleAdvancedFields, id: \.self) { field in
                switch field {
                case .model:
                    AndroidCatalogActionPreferenceRow(
                        title: String(localized: "prompt_model_override", defaultValue: "Model"),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "model_override"),
                        trailingValue: selectedModelTitle,
                        isEnabled: !isReadOnly || origin == .builtIn,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptModelPreference"
                    ) {
                        activeModal = .model
                    }
                case .strictContextMatching:
                    AndroidCatalogSwitchPreferenceRow(
                        title: String(
                            localized: "prompt_strict_context_matching",
                            defaultValue: "Context-dependent cache"
                        ),
                        summary: String(
                            localized: "prompt_strict_context_matching_description",
                            defaultValue: "When enabled, cache matches only when all context (Bible version, selected text) is the same. When disabled, cache matches when verses are the same regardless of Bible version."
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "strict_context_matching"),
                        isOn: $strictContextMatching,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptStrictContextPreference"
                    )
                case .maxIterations:
                    AndroidCatalogActionPreferenceRow(
                        title: String(localized: "prompt_max_iterations", defaultValue: "Max iterations override"),
                        summary: String(
                            localized: "prompt_max_iterations_description",
                            defaultValue: "Override the global max iterations for this prompt. Empty = global default, 0 = unlimited."
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "max_iterations"),
                        trailingValue: maxIterations.isEmpty
                            ? String(localized: "prompt_max_iterations_hint", defaultValue: "Leave empty for global default")
                            : maxIterations,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptMaxIterationsPreference"
                    ) {
                        activeModal = .maxIterations
                    }
                case .specifyBeforeRun:
                    AndroidCatalogSwitchPreferenceRow(
                        title: String(localized: "prompt_edit_before_run", defaultValue: "Specify before run"),
                        summary: String(
                            localized: "prompt_edit_before_run_description",
                            defaultValue: "Show a text field for specifying the task before running the prompt"
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "specify_before_run"),
                        isOn: $specifyBeforeRun,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptSpecifyBeforeRunPreference"
                    )
                case .noDocumentCreation:
                    AndroidCatalogSwitchPreferenceRow(
                        title: String(
                            localized: "prompt_no_document_creation",
                            defaultValue: "No document creation"
                        ),
                        summary: String(
                            localized: "prompt_no_document_creation_description",
                            defaultValue: "When enabled, the AI will not create a document. Results are only shown in the activity log. Useful for action-only prompts (bookmarks, labels, StudyPad operations)."
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "no_document_creation"),
                        isOn: $noDocumentCreation,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptNoDocumentCreationPreference"
                    )
                case .autoIncludeDocuments:
                    AndroidCatalogSwitchPreferenceRow(
                        title: String(
                            localized: "prompt_auto_include_documents",
                            defaultValue: "Auto-include installed documents"
                        ),
                        summary: String(
                            localized: "prompt_auto_include_documents_description",
                            defaultValue: "Automatically include the list of installed documents in the prompt context, saving an AI iteration."
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "auto_include_documents"),
                        isOn: $autoIncludeDocuments,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptAutoIncludeDocumentsPreference"
                    )
                case .autoIncludeCommentaries:
                    AndroidCatalogSwitchPreferenceRow(
                        title: String(
                            localized: "prompt_auto_include_commentaries",
                            defaultValue: "Auto-include commentaries"
                        ),
                        summary: String(
                            localized: "prompt_auto_include_commentaries_description",
                            defaultValue: "Automatically fetch and include commentary entries for the selected verses, saving an AI iteration."
                        ),
                        icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: "auto_include_commentaries"),
                        isOn: $autoIncludeCommentaries,
                        isEnabled: !isReadOnly,
                        palette: surfacePalette,
                        accessibilityIdentifier: "aiPromptAutoIncludeCommentariesPreference"
                    )
                }

                if field != visibleAdvancedFields.last {
                    AndroidPreferenceDivider(palette: surfacePalette)
                }
            }
        }
    }

    /** Returns a mutable context-membership binding. */
    private func contextBinding(_ context: PromptContext) -> Binding<Bool> {
        Binding(
            get: { contexts.contains(context) },
            set: { enabled in
                if enabled { contexts.insert(context) } else { contexts.remove(context) }
            }
        )
    }

    /** Returns a mutable allow/deny/inherit binding for one tool. */
    private func toolBinding(_ tool: AgentTool) -> Binding<AIPromptToolSelection> {
        Binding(
            get: {
                if allowedTools.contains(tool) { return .allow }
                if deniedTools.contains(tool) { return .deny }
                return .inherited
            },
            set: { value in
                allowedTools.remove(tool)
                deniedTools.remove(tool)
                if value == .allow { allowedTools.insert(tool) }
                if value == .deny { deniedTools.insert(tool) }
            }
        )
    }

    /** Loads one effective prompt and preserves its source ownership. */
    private func load() {
        guard let promptID else {
            name = ""
            template = ""
            contexts = [.verseSelection]
            origin = .user
            loaded = true
            return
        }
        do {
            guard let entry = try repository.entryById(promptID) else {
                failureMessage = String(
                    localized: "ai_regenerate_prompt_not_found",
                    defaultValue: "Cannot regenerate: the original prompt was not found. It may have been deleted."
                )
                return
            }
            apply(entry.prompt, origin: entry.origin)
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Replaces every draft field from one effective prompt source.

     - Parameters:
       - prompt: Source prompt whose values become the active editor draft.
       - newOrigin: Ownership controlling editability and toolbar behavior.
     - Side effects: Mutates local SwiftUI draft state only; no persistence is performed.
     - Failure modes: None. Bible-only contexts are normalized exactly as Android does on load.
     */
    private func apply(_ prompt: AgentPrompt, origin newOrigin: PromptOrigin) {
        origin = newOrigin
        name = prompt.name
        description = prompt.promptDescription ?? ""
        template = prompt.promptTemplate
        contexts = AIPromptEditorBehavior.normalizedContexts(
            prompt.showIn,
            bibleOnly: prompt.bibleOnly
        )
        categoryID = prompt.categoryId
        modelID = prompt.configuredModelId
        permissionMode = AIPromptPresentation.selection(for: prompt.permissionMode)
        allowedTools = prompt.allowedTools ?? []
        deniedTools = prompt.deniedTools ?? []
        strictContextMatching = prompt.strictContextMatching
        specifyBeforeRun = prompt.specifyBeforeRun
        noDocumentCreation = prompt.noDocumentCreation
        maxIterations = prompt.maxIterations.map(String.init) ?? ""
        autoIncludeDocuments = prompt.autoIncludeDocuments
        autoIncludeCommentaries = prompt.autoIncludeCommentaries
        bibleOnly = prompt.bibleOnly
        isTextTransformation = prompt.isTextTransformation
        orderNumber = prompt.orderNumber
        createdAtMilliseconds = prompt.createdAtMilliseconds
        selectedTab = .prompt
        loaded = true
    }

    /** Dismisses a clean editor immediately or opens Android's discard confirmation for a dirty draft. */
    private func requestClose() {
        if isDirty {
            showingDiscardConfirmation = true
        } else {
            performDismiss()
        }
    }

    /** Opens Android's prompt-editor help copy in the shared app-owned information dialog. */
    private func showHelp() {
        helpDialog = .help(.promptEditor)
    }

    /**
     Validates Android's required user fields or commits the built-in model override.

     - Side effects: May show validation feedback or delegate to the source-appropriate Save path.
     - Failure modes: Empty required fields retain the draft and show Android's localized message.
     */
    private func validateAndSave() {
        if origin == .builtIn {
            saveBuiltInOverride()
            return
        }
        guard origin == .user else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectedTab = .prompt
            showToast(String(
                localized: "prompt_name_required",
                defaultValue: "Prompt name is required"
            ))
            return
        }
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectedTab = .prompt
            showToast(String(
                localized: "prompt_template_required",
                defaultValue: "Prompt template is required"
            ))
            return
        }
        save()
    }

    /** Commits only a built-in prompt's drafted model override, then closes the editor. */
    private func saveBuiltInOverride() {
        guard origin == .builtIn, let promptID else { return }
        do {
            try repository.setConfiguredModel(promptID: promptID, modelID: modelID)
            onChanged()
            performDismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Deletes the existing user prompt after Android's explicit confirmation and closes the editor. */
    private func deleteAndClose() {
        guard origin == .user, let promptID else { return }
        do {
            try repository.delete(id: promptID)
            onChanged()
            performDismiss()
        } catch {
            showingDeleteConfirmation = false
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Inserts or updates every editable Android prompt field. */
    private func save() {
        let value = AgentPrompt(
            id: promptID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: normalizedDescription,
            promptTemplate: template,
            showIn: contexts,
            orderNumber: promptID == nil ? ((try? settingsStore.userPrompts().count) ?? 0) : orderNumber,
            createdAtMilliseconds: createdAtMilliseconds,
            strictContextMatching: strictContextMatching,
            permissionMode: AIPromptPresentation.mode(for: permissionMode),
            allowedTools: allowedTools.isEmpty ? nil : allowedTools,
            deniedTools: deniedTools.isEmpty ? nil : deniedTools,
            configuredModelId: modelID,
            specifyBeforeRun: specifyBeforeRun,
            noDocumentCreation: noDocumentCreation,
            maxIterations: Int(maxIterations),
            autoIncludeDocuments: autoIncludeDocuments,
            autoIncludeCommentaries: autoIncludeCommentaries,
            bibleOnly: bibleOnly,
            isTextTransformation: isTextTransformation,
            categoryId: categoryID
        )
        do {
            if promptID == nil {
                try repository.insert(value)
            } else {
                try repository.update(value)
            }
            onChanged()
            performDismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /**
     Copies the active prompt and replaces this editor with the editable user-owned copy.

     Android starts a replacement `PromptEditActivity`, finishes the source editor, and displays a
     short success toast. Updating the active identity in place gives the same navigation result
     without leaving the read-only source beneath the copy in the SwiftUI stack.
     */
    private func copyToCustomize() {
        guard let promptID else { return }
        do {
            let copy = try repository.copy(id: promptID)
            self.promptID = copy.id
            apply(copy, origin: .user)
            initialSnapshot = currentSnapshot
            onChanged()
            showToast(String(localized: "prompt_copied", defaultValue: "Prompt copied"))
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Shows one Android-length toast and removes it unless a newer message replaced it. */
    private func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(AndroidToastFeedback.shortDuration))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}

/** Prompt-context and optional permission-mode presentation conversion. */
private enum AIPromptPresentation {
    static func title(for context: PromptContext) -> String {
        switch context {
        case .verseSelection:
            return String(localized: "prompt_context_verse_selection", defaultValue: "Verse selection")
        case .textSelection:
            return String(localized: "prompt_context_text_selection", defaultValue: "Text selection")
        case .windowMenu:
            return String(localized: "prompt_context_window_menu", defaultValue: "Window menu")
        case .workspaceMenu:
            return String(localized: "prompt_context_workspace_menu", defaultValue: "Workspace menu")
        case .noteEditor:
            return String(localized: "prompt_context_note_editor", defaultValue: "Note editor")
        }
    }

    static func selection(for mode: AIPermissionMode?) -> AIPromptPermissionModeSelection {
        switch mode {
        case nil: return .inherited
        case .alwaysAsk: return .alwaysAsk
        case .askOncePerRun: return .askOncePerRun
        case .allowAll: return .allowAll
        case .denyAll: return .denyAll
        }
    }

    static func mode(for selection: AIPromptPermissionModeSelection) -> AIPermissionMode? {
        switch selection {
        case .inherited: return nil
        case .alwaysAsk: return .alwaysAsk
        case .askOncePerRun: return .askOncePerRun
        case .allowAll: return .allowAll
        case .denyAll: return .denyAll
        }
    }
}

/** Category CRUD, visibility, and ordering for built-in and user-owned groups. */
private struct AIPromptCategoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let swordManager: SwordManager?

    @State private var revision = 0
    @State private var newCategoryName = ""
    @State private var showingNewCategory = false
    @State private var deletingCategoryID: UUID?
    @State private var renamingCategoryID: UUID?
    @State private var categoryNameDraft = ""
    @State private var categoryActionDialog: AIPromptCategoryDialogContext?
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    private var repository: PromptRepository {
        PromptRepository(
            settingsStore: settingsStore,
            packProvider: swordManager.map { SwordPromptPackProvider(swordManager: $0) }
        )
    }
    private var categories: [PromptCategory] { (try? repository.allCategories()) ?? [] }

    /// Whether one Android category dialog currently blocks the list and inherited Back action.
    private var isCategoryDialogPresented: Bool {
        categoryActionDialog != nil || showingNewCategory
            || renamingCategoryID != nil || deletingCategoryID != nil
    }

    var body: some View {
        ZStack {
            AndroidActivityScreen(
                title: String(localized: "prompt_category", defaultValue: "Category"),
                accessibilityIdentifier: "aiPromptCategoryTopAppBar",
                palette: .standard,
                onBack: { dismiss() }
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(localized: "new_category", defaultValue: "New category"),
                    accessibilityIdentifier: "aiPromptCategoryAddButton",
                    foregroundColor: ReaderThemeSurfacePalette.standard.toolbarForegroundColor
                ) {
                    newCategoryName = ""
                    showingNewCategory = true
                }
            } content: {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(categories) { category in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.name)
                                        .foregroundStyle(ReaderThemeSurfacePalette.standard.foregroundColor)
                                    if (try? repository.isCategoryHidden(category)) == true {
                                        Text(String(localized: "ai_hidden_status", defaultValue: "hidden"))
                                            .font(.caption)
                                            .foregroundStyle(
                                                ReaderThemeSurfacePalette.standard.secondaryForegroundColor
                                            )
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                            .onLongPressGesture {
                                let isBuiltIn = BuiltInPromptCatalog.categories().contains {
                                    $0.id == category.id
                                }
                                let isHidden = (try? repository.isCategoryHidden(category)) == true
                                categoryActionDialog = AIPromptCategoryDialogContext(
                                    categoryID: category.id,
                                    categoryName: category.name,
                                    isBuiltIn: isBuiltIn,
                                    actions: AIPromptDialogBehavior.categoryActions(
                                        isBuiltIn: isBuiltIn,
                                        isHidden: isHidden,
                                        canMoveUp: categoryMoveTargetID(category.id, offset: -1) != nil,
                                        canMoveDown: categoryMoveTargetID(category.id, offset: 1) != nil
                                    )
                                )
                            }
                            Divider()
                                .overlay(ReaderThemeSurfacePalette.standard.inactiveBorderColor)
                        }
                    }
                    .id(revision)
                }
            }
            .accessibilityHidden(isCategoryDialogPresented)
            .disabled(isCategoryDialogPresented)

            categoryDialogOverlay
        }
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Renders Android's category action, text-entry, and deletion dialogs over this legacy route. */
    @ViewBuilder
    private var categoryDialogOverlay: some View {
        if isCategoryDialogPresented {
            AIPromptDialogOverlay(onDismiss: dismissCategoryDialogs) {
                if let context = categoryActionDialog {
                    AIPromptActionListDialog(
                        title: context.categoryName,
                        actions: context.actions,
                        label: \.title,
                        onSelect: { handleCategoryAction($0, context: context) }
                    )
                } else if showingNewCategory {
                    AIPromptTextInputDialog(
                        title: String(localized: "new_category", defaultValue: "New category"),
                        hint: String(localized: "new_category_name", defaultValue: "Category name"),
                        text: $newCategoryName,
                        onSave: {
                            addCategory()
                            showingNewCategory = false
                        },
                        onCancel: { showingNewCategory = false }
                    )
                } else if renamingCategoryID != nil {
                    AIPromptTextInputDialog(
                        title: String(localized: "rename", defaultValue: "Rename"),
                        hint: String(localized: "new_category_name", defaultValue: "Category name"),
                        text: $categoryNameDraft,
                        onSave: renameCategory,
                        onCancel: { renamingCategoryID = nil }
                    )
                } else if let deletingCategoryID {
                    let name = categories.first(where: { $0.id == deletingCategoryID })?.name ?? ""
                    AIPromptChoiceDialog(
                        title: String.localizedStringWithFormat(
                            String(
                                localized: "delete_category_confirm_title",
                                defaultValue: "Delete category \"%@\"?"
                            ),
                            name
                        ),
                        choices: [false, true],
                        label: {
                            $0
                                ? String(
                                    localized: "delete_category_and_prompts",
                                    defaultValue: "Delete category and its prompts"
                                )
                                : String(
                                    localized: "delete_category_keep_prompts",
                                    defaultValue: "Move prompts to root and delete category"
                                )
                        },
                        onSelect: { deleteCategory(deletePrompts: $0) },
                        onCancel: { self.deletingCategoryID = nil }
                    )
                }
            }
        }
    }

    /** Clears every category-owned dialog without applying its pending action. */
    private func dismissCategoryDialogs() {
        categoryActionDialog = nil
        showingNewCategory = false
        renamingCategoryID = nil
        deletingCategoryID = nil
    }

    /** Routes one Android category-list action and opens chained dialogs where required. */
    private func handleCategoryAction(
        _ action: AIPromptCategoryAction,
        context: AIPromptCategoryDialogContext
    ) {
        categoryActionDialog = nil
        guard let category = categories.first(where: { $0.id == context.categoryID }) else { return }
        switch action {
        case .moveUp:
            move(context.categoryID, offset: -1)
        case .moveDown:
            move(context.categoryID, offset: 1)
        case .hide, .show:
            toggleHidden(category)
        case .rename:
            categoryNameDraft = context.categoryName
            renamingCategoryID = context.categoryID
        case .delete:
            deletingCategoryID = context.categoryID
        }
    }

    /** Returns the adjacent user category for conditional Android move actions. */
    private func categoryMoveTargetID(_ categoryID: UUID, offset: Int) -> UUID? {
        guard let values = try? settingsStore.userCategories(),
              let source = values.firstIndex(where: { $0.id == categoryID }) else { return nil }
        let target = source + offset
        return values.indices.contains(target) ? values[target].id : nil
    }

    /** Inserts a user-owned category at the end of the current order. */
    private func addCategory() {
        let value = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        perform {
            try settingsStore.insertCategory(
                PromptCategory(name: value, orderNumber: (try settingsStore.userCategories()).count)
            )
        }
    }

    /** Persists Android's trimmed category-name draft and closes the rename dialog. */
    private func renameCategory() {
        guard let renamingCategoryID else { return }
        let value = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        perform {
            guard let category = try settingsStore.userCategory(id: renamingCategoryID) else { return }
            category.name = value
            try settingsStore.save()
            self.renamingCategoryID = nil
        }
    }

    /** Applies source-appropriate built-in or user category visibility. */
    private func toggleHidden(_ category: PromptCategory) {
        perform {
            let hidden = try repository.isCategoryHidden(category)
            if BuiltInPromptCatalog.categories().contains(where: { $0.id == category.id }) {
                try repository.setBuiltInCategoryHidden(!hidden, categoryID: category.id)
            } else if let managed = try settingsStore.userCategory(id: category.id) {
                managed.hidden.toggle()
                try settingsStore.save()
            }
        }
    }

    /** Moves one user category and rewrites dense order values. */
    private func move(_ categoryID: UUID, offset: Int) {
        perform {
            var values = try settingsStore.userCategories()
            guard let source = values.firstIndex(where: { $0.id == categoryID }) else { return }
            let target = min(max(source + offset, 0), values.count - 1)
            guard source != target else { return }
            values.swapAt(source, target)
            for (index, category) in values.enumerated() { category.orderNumber = index }
            try settingsStore.save()
        }
    }

    /** Deletes one user category using the chosen prompt disposition. */
    private func deleteCategory(deletePrompts: Bool) {
        guard let deletingCategoryID else { return }
        perform {
            try settingsStore.deleteCategory(id: deletingCategoryID, deletePrompts: deletePrompts)
            self.deletingCategoryID = nil
        }
    }

    /** Runs one category mutation and refreshes or surfaces a generic failure. */
    private func perform(_ mutation: () throws -> Void) {
        do {
            try mutation()
            revision &+= 1
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}
