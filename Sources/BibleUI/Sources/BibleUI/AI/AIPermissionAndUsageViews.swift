// AIPermissionAndUsageViews.swift -- Global AI policy, behavior, usage, and raw logs

import BibleCore
import SwiftData
import SwiftUI
import SwordKit

/** Three-state global override presented for each Android agent tool. */
private enum AIToolPermissionSelection: String, CaseIterable, Identifiable {
    case ask
    case allow
    case deny

    var id: String { rawValue }
}

/** Global permission-mode, per-tool override, and document-access settings. */
struct AIPermissionSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    let swordManager: SwordManager?

    @State private var mode = AIPermissionMode.alwaysAsk
    @State private var allowedTools: Set<AgentTool> = []
    @State private var deniedTools: Set<AgentTool> = []
    @State private var excludedDocuments: Set<String> = []
    @State private var loaded = false
    @State private var failureMessage: String?

    /** Creates permission settings with optional installed-document discovery. */
    init(swordManager: SwordManager? = nil) {
        self.swordManager = swordManager
    }

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }

    private var installedDocuments: [ModuleInfo] {
        (swordManager?.installedModules() ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "prompt_permission_mode", defaultValue: "Permission mode"),
                    selection: $mode
                ) {
                    ForEach(AIPermissionMode.allCases, id: \.self) { value in
                        Text(AIPermissionPresentation.title(for: value)).tag(value)
                    }
                }
                Text(
                    String(
                        localized: "agent_permission_mode_summary",
                        defaultValue: "Controls when user confirmation is required before AI write operations"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(AIPermissionPresentation.categories, id: \.category.rawValue) { group in
                Section(group.title) {
                    ForEach(group.tools, id: \.self) { tool in
                        Picker(AIPermissionPresentation.title(for: tool), selection: permissionBinding(for: tool)) {
                            Text(String(localized: "permission_status_default", defaultValue: "Ask (default)"))
                                .tag(AIToolPermissionSelection.ask)
                            Text(String(localized: "permission_option_always_allow", defaultValue: "Always allow"))
                                .tag(AIToolPermissionSelection.allow)
                            Text(String(localized: "permission_option_always_deny", defaultValue: "Always deny"))
                                .tag(AIToolPermissionSelection.deny)
                        }
                    }
                }
            }

            Section(String(localized: "ai_document_filter_activity_title", defaultValue: "AI document access")) {
                ForEach(installedDocuments, id: \.name) { document in
                    Toggle(
                        isOn: Binding(
                            get: { !excludedDocuments.contains(document.name) },
                            set: { isIncluded in
                                if isIncluded {
                                    excludedDocuments.remove(document.name)
                                } else {
                                    excludedDocuments.insert(document.name)
                                }
                                persist()
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.name)
                            Text(document.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    allowedTools = []
                    deniedTools = []
                    persist()
                } label: {
                    Label(
                        String(localized: "reset_all_permissions", defaultValue: "Reset all"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
        }
        .navigationTitle(String(localized: "manage_tool_permissions_title", defaultValue: "Tool permissions"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { load() }
        .onChange(of: mode) { if loaded { persist() } }
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

    /** Resolves one tool's persisted allow/deny/default state. */
    private func permissionBinding(for tool: AgentTool) -> Binding<AIToolPermissionSelection> {
        Binding(
            get: {
                if allowedTools.contains(tool) { return .allow }
                if deniedTools.contains(tool) { return .deny }
                return .ask
            },
            set: { selection in
                allowedTools.remove(tool)
                deniedTools.remove(tool)
                switch selection {
                case .ask: break
                case .allow: allowedTools.insert(tool)
                case .deny: deniedTools.insert(tool)
                }
                persist()
            }
        )
    }

    /** Loads synced global policy without materializing any provider credentials. */
    private func load() {
        do {
            let settings = try settingsStore.globalSettings()
            mode = settings.agentPermissionMode ?? .alwaysAsk
            allowedTools = settings.permanentlyAllowedTools ?? []
            deniedTools = settings.permanentlyDeniedTools ?? []
            excludedDocuments = settings.aiExcludedDocuments
            loaded = true
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Saves global permission and document-access decisions immediately. */
    private func persist() {
        guard loaded else { return }
        do {
            let settings = try settingsStore.globalSettings()
            settings.agentPermissionMode = mode
            settings.permanentlyAllowedTools = allowedTools.isEmpty ? nil : allowedTools
            settings.permanentlyDeniedTools = deniedTools.isEmpty ? nil : deniedTools
            settings.aiExcludedDocuments = excludedDocuments
            try settingsStore.save()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Stable localized titles and grouping for permission UI and approval dialogs. */
enum AIPermissionPresentation {
    /** One Android tool-category section. */
    struct CategoryGroup {
        let category: AgentTool.Category
        let title: String
        let tools: [AgentTool]
    }

    /// All Android categories in production display order.
    static var categories: [CategoryGroup] {
        let definitions: [(AgentTool.Category, String)] = [
            (.bibleSearch, String(localized: "tool_category_bible_search", defaultValue: "Bible & Search")),
            (.bookmarks, String(localized: "tool_category_bookmarks", defaultValue: "Bookmarks")),
            (.labels, String(localized: "tool_category_labels", defaultValue: "Labels")),
            (.studyPads, String(localized: "tool_category_study_pads", defaultValue: "Study Pads")),
            (.myDocuments, String(localized: "tool_category_my_documents", defaultValue: "My Documents")),
            (.generalBooks, String(localized: "tool_category_general_books", defaultValue: "General Books")),
            (.windows, String(localized: "tool_category_windows", defaultValue: "Windows")),
        ]
        return definitions.map { category, title in
            CategoryGroup(
                category: category,
                title: title,
                tools: AgentTool.allCases.filter { $0.category == category }
            )
        }
    }

    /** Returns Android's localized label for one permission mode. */
    static func title(for mode: AIPermissionMode) -> String {
        switch mode {
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

    /** Returns Android's localized display name for one agent tool. */
    static func title(for tool: AgentTool) -> String {
        switch tool {
        case .getVerseContent:
            return String(localized: "tool_get_verse_content", defaultValue: "Read verse content")
        case .searchBible:
            return String(localized: "tool_search_bible", defaultValue: "Search Bible")
        case .searchByStrongs:
            return String(localized: "tool_search_by_strongs", defaultValue: "Search by Strong's number")
        case .getCommentaries:
            return String(localized: "tool_get_commentaries", defaultValue: "Read commentaries")
        case .getDictionaryEntry:
            return String(localized: "tool_get_dictionary_entry", defaultValue: "Look up dictionary entry")
        case .getBookmarksForVerse:
            return String(localized: "tool_get_bookmarks_for_verse", defaultValue: "Get bookmarks for verse")
        case .getBookmarksWithLabel:
            return String(localized: "tool_get_bookmarks_with_label", defaultValue: "Get bookmarks with label")
        case .getAllLabels:
            return String(localized: "tool_get_all_labels", defaultValue: "List all labels")
        case .getStudyPadContent:
            return String(localized: "tool_get_study_pad_content", defaultValue: "Read study pad content")
        case .searchStudyPads:
            return String(localized: "tool_search_study_pads", defaultValue: "Search study pads")
        case .getInstalledDocuments:
            return String(localized: "tool_get_installed_documents", defaultValue: "List installed documents")
        case .getMyDocuments:
            return String(localized: "tool_get_my_documents", defaultValue: "List My Documents")
        case .getMyDocumentPages:
            return String(localized: "tool_get_my_document_pages", defaultValue: "List My Document pages")
        case .getGenBookKeys:
            return String(localized: "tool_get_genbook_keys", defaultValue: "List general book keys")
        case .getGenBookContent:
            return String(localized: "tool_get_genbook_content", defaultValue: "Read general book content")
        case .getWindows:
            return String(localized: "tool_get_windows", defaultValue: "List windows")
        case .createBookmark:
            return String(localized: "tool_create_bookmark", defaultValue: "Create bookmark")
        case .addBookmarkNote:
            return String(localized: "tool_add_bookmark_note", defaultValue: "Add bookmark note")
        case .updateBookmarkNote:
            return String(localized: "tool_update_bookmark_note", defaultValue: "Update bookmark note")
        case .createLabel:
            return String(localized: "tool_create_label", defaultValue: "Create label")
        case .addLabelToBookmark:
            return String(localized: "tool_add_label_to_bookmark", defaultValue: "Add label to bookmark")
        case .deleteBookmark:
            return String(localized: "tool_delete_bookmark", defaultValue: "Delete bookmark")
        case .deleteLabel:
            return String(localized: "tool_delete_label", defaultValue: "Delete label")
        case .removeLabelFromBookmark:
            return String(localized: "tool_remove_label_from_bookmark", defaultValue: "Remove label from bookmark")
        case .addStudyPadEntry:
            return String(localized: "tool_add_study_pad_entry", defaultValue: "Add study pad entry")
        case .updateStudyPadTextEntry:
            return String(localized: "tool_update_studypad_text_entry", defaultValue: "Update study pad text entry")
        case .createStudyPad:
            return String(localized: "tool_create_study_pad", defaultValue: "Create study pad")
        case .createMyDocument:
            return String(localized: "tool_create_my_document", defaultValue: "Create My Document")
        case .addMyDocumentPage:
            return String(localized: "tool_add_my_document_page", defaultValue: "Add My Document page")
        case .editMyDocumentPage:
            return String(localized: "tool_edit_my_document_page", defaultValue: "Edit My Document page")
        case .deleteMyDocumentPage:
            return String(localized: "tool_delete_my_document_page", defaultValue: "Delete My Document page")
        case .createWindow:
            return String(localized: "tool_create_window", defaultValue: "Create window")
        case .manageWindow:
            return String(localized: "tool_manage_window", defaultValue: "Manage window")
        case .setWindowDocument:
            return String(localized: "tool_set_window_document", defaultValue: "Set window document")
        case .setDocumentTitle:
            return String(localized: "tool_set_document_title", defaultValue: "Set document title")
        case .finishWithStudyPad:
            return String(localized: "tool_finish_with_study_pad", defaultValue: "Open study pad")
        case .finishWithMyDocumentPage:
            return String(localized: "tool_finish_with_my_document_page", defaultValue: "Open My Document page")
        case .finishWithoutDocument:
            return String(localized: "tool_finish_without_document", defaultValue: "Finish without document")
        }
    }
}

/** Global run, language, commentary, cache-prompt, and agent-log behavior settings. */
struct AIBehaviorSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var language = ""
    @State private var askModelBeforeRun = false
    @State private var maxIterations = 10
    @State private var commentaryLimit = 15_000
    @State private var autoHideLog = false
    @State private var agentSystemPrompt = ""
    @State private var transformationSystemPrompt = ""
    @State private var loaded = false
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }

    var body: some View {
        Form {
            Section(String(localized: "ai_behavior_category", defaultValue: "Behavior")) {
                TextField(
                    String(localized: "ai_language_title", defaultValue: "AI response language"),
                    text: $language
                )
                Toggle(
                    String(localized: "ask_model_before_run_title", defaultValue: "Ask model before run"),
                    isOn: $askModelBeforeRun
                )
                Stepper(value: $maxIterations, in: 0...100) {
                    LabeledContent(
                        String(localized: "agent_max_iterations_title", defaultValue: "Max agent iterations"),
                        value: maxIterations == 0
                            ? String(localized: "prompt_max_iterations_unlimited", defaultValue: "Unlimited")
                            : "\(maxIterations)"
                    )
                }
                Stepper(value: $commentaryLimit, in: 0...100_000, step: 1_000) {
                    LabeledContent(
                        String(
                            localized: "commentary_max_response_title",
                            defaultValue: "Commentary response size limit"
                        ),
                        value: commentaryLimit == 0
                            ? String(localized: "commentary_max_response_no_limit", defaultValue: "No limit")
                            : commentaryLimit.formatted()
                    )
                }
                Toggle(
                    String(localized: "auto_hide_agent_log_title", defaultValue: "Hide AI panel when done"),
                    isOn: $autoHideLog
                )
            }

            Section(String(localized: "ai_advanced_category", defaultValue: "Advanced")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "custom_agent_system_prompt_title", defaultValue: "Agent system prompt"))
                        .font(.subheadline)
                    TextEditor(text: $agentSystemPrompt)
                        .frame(minHeight: 120)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        String(
                            localized: "custom_text_transform_system_prompt_title",
                            defaultValue: "Text transformation system prompt"
                        )
                    )
                    .font(.subheadline)
                    TextEditor(text: $transformationSystemPrompt)
                        .frame(minHeight: 120)
                }
                Button {
                    agentSystemPrompt = ""
                    transformationSystemPrompt = ""
                    persist()
                } label: {
                    Label(
                        String(localized: "reset_to_default", defaultValue: "Reset to default"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
        }
        .navigationTitle(String(localized: "ai_behavior_category", defaultValue: "Behavior"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { load() }
        .onDisappear { persist() }
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

    /** Loads global behavior values from the singleton settings row. */
    private func load() {
        do {
            let settings = try settingsStore.globalSettings()
            language = settings.aiLanguage ?? ""
            askModelBeforeRun = settings.askModelBeforeRun
            maxIterations = settings.maxIterations
            commentaryLimit = settings.commentaryMaxResponseTokens
            autoHideLog = settings.autoHideAgentLogOnCompletion
            agentSystemPrompt = settings.customAgentSystemPrompt ?? ""
            transformationSystemPrompt = settings.customTextTransformationSystemPrompt ?? ""
            loaded = true
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Persists behavior fields while preserving nil for inherited language and prompts. */
    private func persist() {
        guard loaded else { return }
        do {
            let settings = try settingsStore.globalSettings()
            settings.aiLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            settings.askModelBeforeRun = askModelBeforeRun
            settings.maxIterations = maxIterations
            settings.commentaryMaxResponseTokens = commentaryLimit
            settings.autoHideAgentLogOnCompletion = autoHideLog
            settings.customAgentSystemPrompt = agentSystemPrompt.nilIfEmpty
            settings.customTextTransformationSystemPrompt = transformationSystemPrompt.nilIfEmpty
            try settingsStore.save()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Usage totals, raw-log retention, inspection, and deletion controls. */
struct AIUsageAndLogsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var revision = 0
    @State private var retentionDays = 30
    @State private var keepsLogsForever = false
    @State private var showingResetUsage = false
    @State private var showingDeleteLogs = false
    @State private var failureMessage: String?

    private var settingsStore: AISettingsStore { AISettingsStore(modelContext: modelContext) }
    private var usage: [LLMUsageRecord] { (try? settingsStore.usageRecords()) ?? [] }
    private var rawLogs: [LLMRawLogRecord] { (try? settingsStore.rawLogs()) ?? [] }

    var body: some View {
        List {
            Section(String(localized: "llm_usage_summary_title", defaultValue: "Token usage")) {
                if usage.isEmpty {
                    Text(String(localized: "llm_usage_summary_default", defaultValue: "No usage data"))
                        .foregroundStyle(.secondary)
                }
                ForEach(usage) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(modelName(for: row.configuredModelId))
                        Text(
                            String(
                                format: String(
                                    localized: "raw_log_item_tokens",
                                    defaultValue: "%1$@ in / %2$@ out"
                                ),
                                row.inputTokens.formatted(),
                                row.outputTokens.formatted()
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.estimatedCostUSD.formatted(.currency(code: "USD")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive) { showingResetUsage = true } label: {
                    Label(
                        String(localized: "llm_reset_usage_title", defaultValue: "Reset usage data"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }

            Section(String(localized: "raw_log_history_title", defaultValue: "AI Log History")) {
                Toggle(
                    String(localized: "raw_log_retention_summary_disabled", defaultValue: "Disabled (keep all)"),
                    isOn: $keepsLogsForever
                )
                if !keepsLogsForever {
                    Picker(
                        String(localized: "raw_log_retention_title", defaultValue: "Auto-delete old logs"),
                        selection: $retentionDays
                    ) {
                        Text(String(localized: "raw_log_older_1_week", defaultValue: "Older than 1 week")).tag(7)
                        Text(String(localized: "raw_log_older_1_month", defaultValue: "Older than 1 month")).tag(30)
                        Text(String(localized: "raw_log_older_3_months", defaultValue: "Older than 3 months")).tag(90)
                    }
                }

                if rawLogs.isEmpty {
                    Text(String(localized: "raw_log_history_empty", defaultValue: "No saved logs"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rawLogs) { log in
                    NavigationLink {
                        AIRawLogDetailView(log: log)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(log.promptName.isEmpty ? log.modelName : log.promptName)
                                if log.wasError {
                                    Text(String(localized: "raw_log_error_indicator", defaultValue: "Error"))
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(Date(timeIntervalSince1970: Double(log.timestampMilliseconds) / 1_000).formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                String(
                                    format: String(
                                        localized: "raw_log_item_tokens",
                                        defaultValue: "%1$@ in / %2$@ out"
                                    ),
                                    log.totalInputTokens.formatted(),
                                    log.totalOutputTokens.formatted()
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !rawLogs.isEmpty {
                    Button(role: .destructive) { showingDeleteLogs = true } label: {
                        Label(String(localized: "raw_log_delete_all", defaultValue: "Delete all"), systemImage: "trash")
                    }
                }
            }
        }
        .id(revision)
        .navigationTitle(String(localized: "ai_usage_category", defaultValue: "Usage"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { loadRetention() }
        .onChange(of: retentionDays) { persistRetention() }
        .onChange(of: keepsLogsForever) { persistRetention() }
        .alert(
            String(localized: "llm_reset_usage_confirm_title", defaultValue: "Reset usage data?"),
            isPresented: $showingResetUsage
        ) {
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "llm_reset_usage_title", defaultValue: "Reset usage data"), role: .destructive) {
                resetUsage()
            }
        } message: {
            Text(
                String(
                    localized: "llm_reset_usage_confirm_message",
                    defaultValue: "This will clear all cumulative usage data."
                )
            )
        }
        .alert(
            String(localized: "raw_log_delete_all", defaultValue: "Delete all"),
            isPresented: $showingDeleteLogs
        ) {
            Button(String(localized: "cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) { deleteAllLogs() }
        }
    }

    /** Resolves a configured model name without retaining provider or credential state. */
    private func modelName(for id: UUID) -> String {
        (try? settingsStore.model(id: id)?.modelId) ?? id.uuidString
    }

    /** Loads nullable Android retention state. */
    private func loadRetention() {
        guard let settings = try? settingsStore.globalSettings() else { return }
        keepsLogsForever = settings.rawLogRetentionDays == nil
        retentionDays = settings.rawLogRetentionDays ?? 30
    }

    /** Saves retention and applies the selected age boundary immediately. */
    private func persistRetention() {
        do {
            let settings = try settingsStore.globalSettings()
            settings.rawLogRetentionDays = keepsLogsForever ? nil : retentionDays
            try settingsStore.save()
            if !keepsLogsForever {
                let boundary = Int64(Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970 * 1_000)
                try settingsStore.deleteRawLogs(olderThan: boundary)
                revision &+= 1
            }
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Zeros cumulative usage rows while retaining their model/device aggregation identity. */
    private func resetUsage() {
        do {
            for row in try settingsStore.usageRecords() {
                row.inputTokens = 0
                row.outputTokens = 0
                row.cacheCreationTokens = 0
                row.cacheReadTokens = 0
                row.estimatedCostUSD = 0
            }
            try settingsStore.save()
            revision &+= 1
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Deletes every device-local raw log without touching synced settings or credentials. */
    private func deleteAllLogs() {
        do {
            try settingsStore.deleteRawLogs(olderThan: .max)
            revision &+= 1
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }
}

/** Read-only native view of one credential-free local raw conversation log. */
private struct AIRawLogDetailView: View {
    let log: LLMRawLogRecord

    var body: some View {
        ScrollView {
            Text(String(data: log.logData, encoding: .utf8) ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(String(localized: "agent_log_view_raw", defaultValue: "View raw LLM log"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private extension String {
    /// Nil-preserving helper for optional Android text settings.
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
