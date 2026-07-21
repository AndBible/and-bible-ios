// AIPromptManagementView.swift -- Prompt, category, source, and behavior editing

import BibleCore
import SwiftData
import SwiftUI
import SwordKit

/** Prompt-manager destination for built-in, add-on, and user-authored actions. */
public struct AIPromptManagementView: View {
    @Environment(\.modelContext) private var modelContext

    private let swordManager: SwordManager?

    @State private var revision = 0
    @State private var failureMessage: String?
    @State private var deletingPromptID: UUID?

    /** Creates a manager with optional SWORD add-on prompt discovery. */
    public init(swordManager: SwordManager? = nil) {
        self.swordManager = swordManager
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

    public var body: some View {
        List {
            if !favoriteIDs.isEmpty {
                promptSection(
                    String(localized: "prompt_category_favorites", defaultValue: "Favorites"),
                    entries: entries.filter { favoriteIDs.contains($0.prompt.id) }
                )
            }

            promptSection(
                String(localized: "built_in_prompt", defaultValue: "Built-in"),
                entries: entries.filter { $0.origin == .builtIn }
            )

            let addOns = entries.filter {
                if case .swordPack = $0.origin { return true }
                return false
            }
            if !addOns.isEmpty {
                promptSection(
                    String(localized: "doc_type_addons", defaultValue: "Add-ons"),
                    entries: addOns
                )
            }

            promptSection(
                String(localized: "custom_system_prompt_custom", defaultValue: "Custom"),
                entries: entries.filter { $0.origin == .user }
            )

            Section {
                NavigationLink {
                    AIPromptEditorView(promptID: nil, swordManager: swordManager, onChanged: refresh)
                } label: {
                    Label(String(localized: "new_prompt", defaultValue: "New prompt"), systemImage: "plus")
                }
                NavigationLink {
                    AIPromptCategoryManagementView(swordManager: swordManager)
                } label: {
                    Label(String(localized: "prompt_category", defaultValue: "Category"), systemImage: "folder")
                }
            }
        }
        .id(revision)
        .navigationTitle(String(localized: "manage_prompts", defaultValue: "Manage AI Prompts"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            String(localized: "delete", defaultValue: "Delete"),
            isPresented: Binding(
                get: { deletingPromptID != nil },
                set: { if !$0 { deletingPromptID = nil } }
            )
        ) {
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                if let deletingPromptID { deletePrompt(deletingPromptID) }
            }
        }
        .alert(
            String(localized: "error", defaultValue: "Error"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK")) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /** Builds one source-grouped prompt section with direct favorite and action controls. */
    @ViewBuilder
    private func promptSection(_ title: String, entries sectionEntries: [ResolvedAgentPrompt]) -> some View {
        if !sectionEntries.isEmpty {
            Section(title) {
                ForEach(sectionEntries, id: \.prompt.id) { entry in
                    HStack(spacing: 10) {
                        Button {
                            setFavorite(!favoriteIDs.contains(entry.prompt.id), promptID: entry.prompt.id)
                        } label: {
                            Image(systemName: favoriteIDs.contains(entry.prompt.id) ? "star.fill" : "star")
                                .foregroundStyle(favoriteIDs.contains(entry.prompt.id) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        NavigationLink {
                            AIPromptEditorView(
                                promptID: entry.prompt.id,
                                swordManager: swordManager,
                                onChanged: refresh
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.prompt.name)
                                if let description = entry.prompt.promptDescription, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if entry.origin == .builtIn, hiddenBuiltInIDs.contains(entry.prompt.id) {
                                    Text(String(localized: "ai_hidden_status", defaultValue: "hidden"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Menu {
                            Button {
                                copyPrompt(entry.prompt.id)
                            } label: {
                                Label(
                                    String(localized: "copy_to_customize", defaultValue: "Copy to customize"),
                                    systemImage: "doc.on.doc"
                                )
                            }
                            if entry.origin == .builtIn {
                                Button {
                                    setBuiltInHidden(
                                        !hiddenBuiltInIDs.contains(entry.prompt.id),
                                        promptID: entry.prompt.id
                                    )
                                } label: {
                                    Label(
                                        hiddenBuiltInIDs.contains(entry.prompt.id)
                                            ? String(localized: "show_category", defaultValue: "Show in AI actions")
                                            : String(localized: "ai_hide_prompt", defaultValue: "Hide"),
                                        systemImage: hiddenBuiltInIDs.contains(entry.prompt.id) ? "eye" : "eye.slash"
                                    )
                                }
                            }
                            if entry.origin == .user {
                                Button {
                                    movePrompt(entry.prompt.id, offset: -1)
                                } label: {
                                    Label(String(localized: "move_category_up", defaultValue: "Move up"), systemImage: "arrow.up")
                                }
                                Button {
                                    movePrompt(entry.prompt.id, offset: 1)
                                } label: {
                                    Label(String(localized: "move_category_down", defaultValue: "Move down"), systemImage: "arrow.down")
                                }
                                Button(role: .destructive) {
                                    deletingPromptID = entry.prompt.id
                                } label: {
                                    Label(String(localized: "delete", defaultValue: "Delete"), systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
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

    /** Moves one user prompt within Android's integer ordering. */
    private func movePrompt(_ promptID: UUID, offset: Int) {
        perform {
            var prompts = try settingsStore.userPrompts()
            guard let sourceIndex = prompts.firstIndex(where: { $0.id == promptID }) else { return }
            let targetIndex = min(max(sourceIndex + offset, 0), prompts.count - 1)
            guard sourceIndex != targetIndex else { return }
            prompts.swapAt(sourceIndex, targetIndex)
            for (index, prompt) in prompts.enumerated() {
                prompt.orderNumber = index
            }
            try settingsStore.save()
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

    /** Invalidates source-grouped prompt snapshots after a mutation or child dismissal. */
    private func refresh() {
        revision &+= 1
    }
}

/** Prompt editor tab identity. */
private enum AIPromptEditorTab: String, CaseIterable, Identifiable {
    case prompt
    case permissions
    case advanced

    var id: String { rawValue }
}

/** Optional per-prompt permission-mode selection. */
private enum AIPromptPermissionModeSelection: String, CaseIterable, Identifiable {
    case inherited
    case alwaysAsk
    case askOncePerRun
    case allowAll
    case denyAll

    var id: String { rawValue }
}

/** Per-prompt tool availability override state. */
private enum AIPromptToolSelection: String, CaseIterable, Identifiable {
    case inherited
    case allow
    case deny

    var id: String { rawValue }
}

/** Full source-aware prompt editor used by settings and generated-document source links. */
struct AIPromptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let promptID: UUID?
    let swordManager: SwordManager?
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
    @State private var failureMessage: String?

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

    /** Trims optional descriptive copy before it crosses the persistence boundary. */
    private var normalizedDescription: String? {
        let value = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(String(localized: "prompt_tab_prompt", defaultValue: "Prompt")).tag(AIPromptEditorTab.prompt)
                Text(String(localized: "prompt_tab_permissions", defaultValue: "Permissions")).tag(AIPromptEditorTab.permissions)
                Text(String(localized: "prompt_tab_advanced", defaultValue: "Advanced")).tag(AIPromptEditorTab.advanced)
            }
            .pickerStyle(.segmented)
            .padding()

            Form {
                switch selectedTab {
                case .prompt: promptFields
                case .permissions: permissionFields
                case .advanced: advancedFields
                }
            }
        }
        .navigationTitle(promptID == nil ? String(localized: "new_prompt", defaultValue: "New prompt") : name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if origin == .user {
                    Button(String(localized: "save", defaultValue: "Save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button {
                        copyToCustomize()
                    } label: {
                        Label(
                            String(localized: "copy_to_customize", defaultValue: "Copy to customize"),
                            systemImage: "doc.on.doc"
                        )
                    }
                }
            }
        }
        .task { load() }
        .alert(
            String(localized: "error", defaultValue: "Error"),
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button(String(localized: "okay", defaultValue: "OK")) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    /** Main prompt text, context, category, and model fields. */
    @ViewBuilder
    private var promptFields: some View {
        if isReadOnly {
            Section {
                Label(
                    String(
                        localized: "built_in_prompt_notice",
                        defaultValue: "This is a built-in prompt and cannot be edited. Use \"Copy to customize\" to create an editable copy."
                    ),
                    systemImage: "lock"
                )
                .font(.subheadline)
            }
        }
        Section {
            TextField(String(localized: "prompt_name", defaultValue: "Name"), text: $name)
                .disabled(isReadOnly)
            TextField(String(localized: "prompt_description", defaultValue: "Description"), text: $description, axis: .vertical)
                .disabled(isReadOnly)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "prompt_template", defaultValue: "Prompt template"))
                    .font(.subheadline)
                TextEditor(text: $template)
                    .frame(minHeight: 180)
                    .disabled(isReadOnly)
            }
        }
        Section(String(localized: "prompt_show_in", defaultValue: "Show in")) {
            ForEach(PromptContext.allCases, id: \.self) { context in
                Toggle(AIPromptPresentation.title(for: context), isOn: contextBinding(context))
                    .disabled(isReadOnly)
            }
        }
        Section {
            Picker(String(localized: "prompt_category", defaultValue: "Category"), selection: $categoryID) {
                Text(String(localized: "category_none", defaultValue: "No category")).tag(UUID?.none)
                ForEach(categories) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
            .disabled(isReadOnly)
            Picker(String(localized: "prompt_model_override", defaultValue: "Model"), selection: $modelID) {
                Text(String(localized: "prompt_model_default", defaultValue: "Default")).tag(UUID?.none)
                ForEach(models) { model in
                    Text(model.modelId).tag(Optional(model.id))
                }
            }
            .onChange(of: modelID) {
                if loaded, isReadOnly, origin == .builtIn, let promptID {
                    do {
                        try repository.setConfiguredModel(promptID: promptID, modelID: modelID)
                        onChanged()
                    } catch {
                        failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
                    }
                }
            }
        }
    }

    /** Per-prompt mode and complete allowed/denied tool controls. */
    @ViewBuilder
    private var permissionFields: some View {
        Section {
            Picker(
                String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
                selection: $permissionMode
            ) {
                Text(String(localized: "prompt_permission_use_default", defaultValue: "Use default"))
                    .tag(AIPromptPermissionModeSelection.inherited)
                Text(String(localized: "permission_always_ask", defaultValue: "Always ask"))
                    .tag(AIPromptPermissionModeSelection.alwaysAsk)
                Text(String(localized: "permission_ask_once_per_run", defaultValue: "Ask once per run"))
                    .tag(AIPromptPermissionModeSelection.askOncePerRun)
                Text(String(localized: "permission_allow_all", defaultValue: "Allow all"))
                    .tag(AIPromptPermissionModeSelection.allowAll)
                Text(String(localized: "permission_deny_all", defaultValue: "Deny all"))
                    .tag(AIPromptPermissionModeSelection.denyAll)
            }
            .disabled(isReadOnly)
            Text(
                String(
                    localized: "prompt_permission_mode_description",
                    defaultValue: "Controls when user confirmation is required before the AI performs write operations. The per-tool settings below can override this for individual tools."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(AIPermissionPresentation.categories, id: \.category.rawValue) { group in
            Section(group.title) {
                ForEach(group.tools, id: \.self) { tool in
                    Picker(AIPermissionPresentation.title(for: tool), selection: toolBinding(tool)) {
                        Text(String(localized: "prompt_permission_use_default", defaultValue: "Use default"))
                            .tag(AIPromptToolSelection.inherited)
                        Text(String(localized: "permission_option_always_allow", defaultValue: "Always allow"))
                            .tag(AIPromptToolSelection.allow)
                        Text(String(localized: "permission_option_always_deny", defaultValue: "Always deny"))
                            .tag(AIPromptToolSelection.deny)
                    }
                    .disabled(isReadOnly)
                }
            }
        }
    }

    /** Iteration, cache, context prefetch, and result-routing fields. */
    @ViewBuilder
    private var advancedFields: some View {
        Section {
            Toggle(String(localized: "prompt_edit_before_run", defaultValue: "Specify before run"), isOn: $specifyBeforeRun)
            Toggle(String(localized: "prompt_no_document_creation", defaultValue: "No document creation"), isOn: $noDocumentCreation)
            Toggle(String(localized: "prompt_bible_only", defaultValue: "Bible documents only"), isOn: $bibleOnly)
            Toggle(String(localized: "prompt_is_text_transformation", defaultValue: "Text transformation"), isOn: $isTextTransformation)
        }
        .disabled(isReadOnly)

        Section {
            TextField(
                String(localized: "prompt_max_iterations_hint", defaultValue: "Leave empty for global default"),
                text: $maxIterations
            )
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            Toggle(
                String(localized: "prompt_strict_context_matching", defaultValue: "Context-dependent cache"),
                isOn: $strictContextMatching
            )
        }
        .disabled(isReadOnly)

        Section {
            Toggle(
                String(localized: "prompt_auto_include_documents", defaultValue: "Auto-include installed documents"),
                isOn: $autoIncludeDocuments
            )
            Toggle(
                String(localized: "prompt_auto_include_commentaries", defaultValue: "Auto-include commentaries"),
                isOn: $autoIncludeCommentaries
            )
        }
        .disabled(isReadOnly)
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
            origin = entry.origin
            let prompt = entry.prompt
            name = prompt.name
            description = prompt.promptDescription ?? ""
            template = prompt.promptTemplate
            contexts = prompt.showIn
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
            loaded = true
        } catch {
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
            dismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Copies the current read-only source prompt into user-owned persistence. */
    private func copyToCustomize() {
        guard let promptID else { return }
        do {
            _ = try repository.copy(id: promptID)
            onChanged()
            dismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
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
    @Environment(\.modelContext) private var modelContext

    let swordManager: SwordManager?

    @State private var revision = 0
    @State private var newCategoryName = ""
    @State private var showingNewCategory = false
    @State private var deletingCategoryID: UUID?
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    private var repository: PromptRepository {
        PromptRepository(
            settingsStore: settingsStore,
            packProvider: swordManager.map { SwordPromptPackProvider(swordManager: $0) }
        )
    }
    private var categories: [PromptCategory] { (try? repository.allCategories()) ?? [] }

    var body: some View {
        List {
            ForEach(categories) { category in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                        if (try? repository.isCategoryHidden(category)) == true {
                            Text(String(localized: "ai_hidden_status", defaultValue: "hidden"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button {
                            toggleHidden(category)
                        } label: {
                            Label(
                                (try? repository.isCategoryHidden(category)) == true
                                    ? String(localized: "show_category", defaultValue: "Show in AI actions")
                                    : String(localized: "hide_category", defaultValue: "Hide from AI actions"),
                                systemImage: (try? repository.isCategoryHidden(category)) == true ? "eye" : "eye.slash"
                            )
                        }
                        if !BuiltInPromptCatalog.categories().contains(where: { $0.id == category.id }) {
                            Button { move(category.id, offset: -1) } label: {
                                Label(String(localized: "move_category_up", defaultValue: "Move up"), systemImage: "arrow.up")
                            }
                            Button { move(category.id, offset: 1) } label: {
                                Label(String(localized: "move_category_down", defaultValue: "Move down"), systemImage: "arrow.down")
                            }
                            Button(role: .destructive) { deletingCategoryID = category.id } label: {
                                Label(String(localized: "delete_category", defaultValue: "Delete category"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            Button {
                newCategoryName = ""
                showingNewCategory = true
            } label: {
                Label(String(localized: "new_category", defaultValue: "New category"), systemImage: "plus")
            }
        }
        .id(revision)
        .navigationTitle(String(localized: "prompt_category", defaultValue: "Category"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(String(localized: "new_category", defaultValue: "New category"), isPresented: $showingNewCategory) {
            TextField(String(localized: "new_category_name", defaultValue: "Category name"), text: $newCategoryName)
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "save", defaultValue: "Save")) { addCategory() }
        }
        .confirmationDialog(
            String(localized: "delete_category", defaultValue: "Delete category"),
            isPresented: Binding(
                get: { deletingCategoryID != nil },
                set: { if !$0 { deletingCategoryID = nil } }
            )
        ) {
            Button(String(localized: "delete_category_keep_prompts", defaultValue: "Move prompts to root and delete category")) {
                deleteCategory(deletePrompts: false)
            }
            Button(String(localized: "delete_category_and_prompts", defaultValue: "Delete category and its prompts"), role: .destructive) {
                deleteCategory(deletePrompts: true)
            }
        }
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
