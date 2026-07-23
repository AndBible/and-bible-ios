// AIToolAndDocumentSettingsViews.swift -- Android AI access-control destinations

import BibleCore
import SwiftData
import SwiftUI
import SwordKit

/** Three-state global override shown for Android write tools. */
private enum AIToolOverrideSelection: String, CaseIterable, Identifiable {
    /// Inherit Android's default ask behavior.
    case ask
    /// Permanently allow the tool.
    case allow
    /// Permanently deny or disable the tool.
    case deny

    /// Stable segmented-control identity.
    var id: String { rawValue }
}

/** App-owned Android discard-confirmation overlay shared by explicit-save AI screens. */
private struct AISettingsDiscardOverlay: View {
    /// Current appearance used by the globally managed Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Confirms discarding all unsaved drafts.
    let onDiscard: () -> Void
    /// Returns to editing without changing draft or persistence.
    let onCancel: () -> Void

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "aiDiscardChangesDialog",
            allowsOutsideDismissal: false,
            onOutsideTap: {}
        ) {
            AIAndroidDialogSurface(title: "") {
                Text(String(localized: "discard_changes_confirmation", defaultValue: "Discard unsaved changes?"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } actions: {
                Spacer()
                AIAndroidDialogAction(
                    title: String(localized: "no", defaultValue: "No"),
                    action: onCancel
                )
                AIAndroidDialogAction(
                    title: String(localized: "yes", defaultValue: "Yes"),
                    isDestructive: true,
                    action: onDiscard
                )
            }
        }
        .zIndex(20)
    }
}

/**
 Android's full-screen global tool-permission editor.

 The view drafts category toggles and per-tool choices locally, then writes both global override sets
 only through the toolbar Save action. Back navigation asks before discarding dirty state, matching
 `GlobalToolPermissionsActivity` rather than persisting every picker change immediately.
 */
struct AIToolPermissionsView: View {
    /// Pops the pushed Android-style destination after save or confirmed discard.
    @Environment(\.dismiss) private var dismiss
    /// SwiftData context containing Android's global allow and deny sets.
    @Environment(\.modelContext) private var modelContext
    /// Current appearance used by the shared overflow menu.
    @Environment(\.colorScheme) private var colorScheme

    /// Reader/workspace palette inherited from Connection settings.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command returning to Connection settings.
    let onBack: (() -> Void)?

    /// Draft tools that bypass write confirmation.
    @State private var allowedTools: Set<AgentTool> = []
    /// Draft tools that are denied or read-disabled.
    @State private var deniedTools: Set<AgentTool> = []
    /// Original allow set used for dirty-state comparison.
    @State private var initialAllowedTools: Set<AgentTool> = []
    /// Original deny set used for dirty-state comparison.
    @State private var initialDeniedTools: Set<AgentTool> = []
    /// Categories whose tool rows are currently expanded.
    @State private var expandedCategories: Set<AgentTool.Category> = []
    /// Whether Android's discard confirmation is visible.
    @State private var showsDiscardConfirmation = false
    /// Credential-free persistence error.
    @State private var failureMessage: String?
    /// Android's app-owned Help dialog.
    @State private var helpDialog: AIConfigurationDialog?
    /// Whether Android's app-owned action-bar overflow is visible.
    @State private var showsOverflowMenu = false

    /** Creates the explicit-save tool-permission activity without loading persistence. */
    init(
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    /// Whether any draft differs from its loaded persisted value.
    private var isDirty: Bool {
        allowedTools != initialAllowedTools || deniedTools != initialDeniedTools
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(
                    localized: "global_tool_permissions_title",
                    defaultValue: "Default tool settings"
                ),
                accessibilityIdentifier: "aiToolPermissionsTopAppBar",
                palette: surfacePalette,
                onBack: requestClose
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivitySave"),
                    accessibilityLabel: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "aiToolPermissionsSaveButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: saveAndClose
                )
                .disabled(showsDiscardConfirmation || helpDialog != nil)

                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "aiToolPermissionsOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showsOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: "aiToolPermissionsOverflowAnchor")
                .disabled(showsDiscardConfirmation || helpDialog != nil)
            } content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(AIPermissionPresentation.categories, id: \.category.rawValue) { group in
                            categoryHeader(group)
                        if expandedCategories.contains(group.category) {
                            ForEach(group.tools, id: \.self) { tool in
                                toolRow(tool)
                            }
                        }
                            AndroidPreferenceDivider(palette: surfacePalette)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityHidden(showsDiscardConfirmation || helpDialog != nil)
                .disabled(showsDiscardConfirmation || helpDialog != nil || showsOverflowMenu)
            }

            AndroidActivityAccessibilityMarker(
                label: String(
                    localized: "global_tool_permissions_title",
                    defaultValue: "Default tool settings"
                ),
                accessibilityIdentifier: "aiToolPermissionsScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
            .accessibilityHidden(showsDiscardConfirmation || helpDialog != nil)

            if showsDiscardConfirmation {
                AISettingsDiscardOverlay(
                    onDiscard: performDismiss,
                    onCancel: { showsDiscardConfirmation = false }
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: "aiToolPermissionsOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: 104,
            accessibilityIdentifier: "aiToolPermissionsOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiToolPermissionsOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(spacing: 0) {
                    AndroidPopupMenuRow(
                        title: String(localized: "reset_all_permissions", defaultValue: "Reset all"),
                        accessibilityIdentifier: "aiToolPermissionsResetMenuItem"
                    ) {
                        showsOverflowMenu = false
                        resetAll()
                    }
                    Divider()
                    AndroidPopupMenuRow(
                        title: String(localized: "help", defaultValue: "Help"),
                        accessibilityIdentifier: "aiToolPermissionsHelpMenuItem"
                    ) {
                        showsOverflowMenu = false
                        helpDialog = .information(
                            title: String(localized: "help", defaultValue: "Help"),
                            message: String(
                                localized: "help_global_tool_permissions_text",
                                defaultValue: "Configure permissions for individual AI tools. For each read tool, choose whether the AI may use it (Enabled or Disabled). For each write tool, choose Always allow, Always deny, or Ask (which falls back to the global permission mode set in AI Connection settings)."
                            )
                        )
                    }
                }
            }
        }
        .task { load() }
        .aiConfigurationDialog($helpDialog, credentialStore: .keychain())
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Builds Android's category header with expansion and read/write group toggles. */
    private func categoryHeader(_ group: AIPermissionPresentation.CategoryGroup) -> some View {
        let readTools = group.tools.filter { $0.access == .read }
        let writeTools = group.tools.filter { $0.access != .read }
        return HStack(spacing: 8) {
            Button {
                if expandedCategories.contains(group.category) {
                    expandedCategories.remove(group.category)
                } else {
                    expandedCategories.insert(group.category)
                }
            } label: {
                Image(systemName: expandedCategories.contains(group.category) ? "chevron.up" : "chevron.down")
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                Text(group.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(surfacePalette.foregroundColor)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if !readTools.isEmpty {
                categoryToggle(
                    title: String(localized: "tool_category_read", defaultValue: "Read"),
                    tools: readTools
                )
            }
            if !writeTools.isEmpty {
                categoryToggle(
                    title: String(localized: "tool_category_write", defaultValue: "Write"),
                    tools: writeTools
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(surfacePalette.backgroundColor)
    }

    /** Builds one Android category checkbox controlling all tools of the supplied access class. */
    private func categoryToggle(title: String, tools: [AgentTool]) -> some View {
        let isEnabled = tools.allSatisfy { !deniedTools.contains($0) }
        return Button {
            for tool in tools {
                allowedTools.remove(tool)
                if isEnabled {
                    deniedTools.insert(tool)
                } else {
                    deniedTools.remove(tool)
                }
            }
            updateExpansion(for: tools.first?.category)
        } label: {
            HStack(spacing: 4) {
                AndroidCheckboxIndicator(
                    isOn: isEnabled,
                    uncheckedColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor
                )
                Text(title)
                    .foregroundStyle(surfacePalette.foregroundColor)
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
    }

    /** Builds Android's read two-option or write three-option tool row. */
    private func toolRow(_ tool: AgentTool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AIPermissionPresentation.title(for: tool))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(surfacePalette.foregroundColor)
            HStack(alignment: .top, spacing: 8) {
                AndroidRadioRow(
                    title: tool.access == .read
                        ? String(localized: "tool_option_enabled", defaultValue: "Enabled")
                        : String(localized: "permission_status_default", defaultValue: "Ask (default)"),
                    value: AIToolOverrideSelection.ask,
                    selection: permissionBinding(for: tool),
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    titleFont: .caption
                )
                if tool.access != .read {
                    AndroidRadioRow(
                        title: String(
                            localized: "permission_option_always_allow",
                            defaultValue: "Always allow"
                        ),
                        value: AIToolOverrideSelection.allow,
                        selection: permissionBinding(for: tool),
                        foregroundColor: surfacePalette.foregroundColor,
                        secondaryColor: surfacePalette.secondaryForegroundColor,
                        accentColor: surfacePalette.controlAccentColor,
                        titleFont: .caption
                    )
                }
                AndroidRadioRow(
                    title: tool.access == .read
                        ? String(localized: "tool_option_disabled", defaultValue: "Disabled")
                        : String(localized: "permission_option_always_deny", defaultValue: "Always deny"),
                    value: AIToolOverrideSelection.deny,
                    selection: permissionBinding(for: tool),
                    foregroundColor: surfacePalette.foregroundColor,
                    secondaryColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    titleFont: .caption
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(surfacePalette.backgroundColor)
    }

    /** Resolves and mutates one tool's draft Android override state. */
    private func permissionBinding(for tool: AgentTool) -> Binding<AIToolOverrideSelection> {
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
                updateExpansion(for: tool.category)
            }
        )
    }

    /** Loads durable override sets and Android's initial collapsed-category state. */
    private func load() {
        do {
            let settings = try AISettingsStore(modelContext: modelContext).globalSettings()
            allowedTools = settings.permanentlyAllowedTools ?? []
            deniedTools = settings.permanentlyDeniedTools ?? []
            initialAllowedTools = allowedTools
            initialDeniedTools = deniedTools
            expandedCategories = Set(
                AIPermissionPresentation.categories.compactMap { group in
                    group.tools.allSatisfy(deniedTools.contains) ? nil : group.category
                }
            )
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Resets every draft row to Android's inherited/default state without saving. */
    private func resetAll() {
        allowedTools = []
        deniedTools = []
        expandedCategories = Set(AIPermissionPresentation.categories.map(\.category))
    }

    /** Saves both override sets atomically and pops the destination. */
    private func saveAndClose() {
        do {
            let store = AISettingsStore(modelContext: modelContext)
            let settings = try store.globalSettings()
            settings.permanentlyAllowedTools = allowedTools
            settings.permanentlyDeniedTools = deniedTools
            try store.save()
            performDismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Pops clean state immediately or opens Android's dirty-state discard dialog. */
    private func requestClose() {
        if isDirty { showsDiscardConfirmation = true } else { performDismiss() }
    }

    /** Returns through the explicit Connection settings owner or environment fallback. */
    private func performDismiss() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /** Auto-collapses a category only when every contained tool is denied. */
    private func updateExpansion(for category: AgentTool.Category?) {
        guard let category,
              let tools = AIPermissionPresentation.categories.first(where: { $0.category == category })?.tools
        else { return }
        if tools.allSatisfy(deniedTools.contains) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }
}

/**
 Android's full-screen installed-document access editor.

 Checked rows are readable by AI and unchecked rows are stored in the global exclusion set. Drafts
 are grouped by SWORD category, saved only through the toolbar, and protected by discard confirmation.
 */
struct AIDocumentAccessView: View {
    /// Pops the pushed destination.
    @Environment(\.dismiss) private var dismiss
    /// SwiftData context containing the exclusion set.
    @Environment(\.modelContext) private var modelContext
    /// Current appearance used by the shared overflow menu.
    @Environment(\.colorScheme) private var colorScheme

    /// Installed SWORD module source supplied by the reader/application host.
    let swordManager: SwordManager?
    /// Reader/workspace palette inherited from Connection settings.
    let surfacePalette: ReaderThemeSurfacePalette
    /// Explicit Android Up command returning to Connection settings.
    let onBack: (() -> Void)?

    /// Draft excluded module initials.
    @State private var excludedDocuments: Set<String> = []
    /// Android-compatible installed-book inventory loaded when the destination opens.
    @State private var installedDocuments: [ModuleInfo] = []
    /// Loaded exclusion set used for dirty-state comparison.
    @State private var initialExcludedDocuments: Set<String> = []
    /// Whether Android's discard confirmation is visible.
    @State private var showsDiscardConfirmation = false
    /// Credential-free persistence failure.
    @State private var failureMessage: String?
    /// Android's app-owned Help dialog.
    @State private var helpDialog: AIConfigurationDialog?
    /// Whether Android's app-owned action-bar overflow is visible.
    @State private var showsOverflowMenu = false

    /** Creates the explicit-save document-access activity without loading module state. */
    init(
        swordManager: SwordManager?,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onBack: (() -> Void)? = nil
    ) {
        self.swordManager = swordManager
        self.surfacePalette = surfacePalette
        self.onBack = onBack
    }

    /// Android-supported categories and their installed modules.
    private var documentGroups: [(category: ModuleCategory, documents: [ModuleInfo])] {
        let categories: [ModuleCategory] = [.bible, .commentary, .dictionary, .generalBook]
        return categories.compactMap { category in
            let documents = installedDocuments
                .filter { $0.category == category }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return documents.isEmpty ? nil : (category, documents)
        }
    }

    /// Whether the draft exclusion set differs from persistence.
    private var isDirty: Bool { excludedDocuments != initialExcludedDocuments }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(
                    localized: "ai_document_filter_activity_title",
                    defaultValue: "AI document access"
                ),
                accessibilityIdentifier: "aiDocumentAccessTopAppBar",
                palette: surfacePalette,
                onBack: requestClose
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivitySave"),
                    accessibilityLabel: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "aiDocumentAccessSaveButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: saveAndClose
                )
                .disabled(showsDiscardConfirmation || helpDialog != nil)

                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "aiDocumentAccessOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    showsOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: "aiDocumentAccessOverflowAnchor")
                .disabled(showsDiscardConfirmation || helpDialog != nil)
            } content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(documentGroups, id: \.category.rawValue) { group in
                            AndBibleSettingsSectionHeader(
                                title: documentCategoryTitle(group.category),
                                accentColor: surfacePalette.controlAccentColor
                            )
                        ForEach(group.documents, id: \.name) { document in
                            documentRow(document)
                        }
                            AndroidPreferenceDivider(palette: surfacePalette)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityHidden(showsDiscardConfirmation || helpDialog != nil)
                .disabled(showsDiscardConfirmation || helpDialog != nil || showsOverflowMenu)
            }

            AndroidActivityAccessibilityMarker(
                label: String(
                    localized: "ai_document_filter_activity_title",
                    defaultValue: "AI document access"
                ),
                accessibilityIdentifier: "aiDocumentAccessScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
            .accessibilityHidden(showsDiscardConfirmation || helpDialog != nil)

            if showsDiscardConfirmation {
                AISettingsDiscardOverlay(
                    onDiscard: performDismiss,
                    onCancel: { showsDiscardConfirmation = false }
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: "aiDocumentAccessOverflowAnchor",
            isPresented: $showsOverflowMenu,
            menuWidth: 260,
            estimatedMenuHeight: 104,
            accessibilityIdentifier: "aiDocumentAccessOverflowMenu"
        ) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "aiDocumentAccessOverflowMenu",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(spacing: 0) {
                    AndroidPopupMenuRow(
                        title: String(localized: "reset_all_permissions", defaultValue: "Reset all"),
                        accessibilityIdentifier: "aiDocumentAccessResetMenuItem"
                    ) {
                        showsOverflowMenu = false
                        excludedDocuments = []
                    }
                    Divider()
                    AndroidPopupMenuRow(
                        title: String(localized: "help", defaultValue: "Help"),
                        accessibilityIdentifier: "aiDocumentAccessHelpMenuItem"
                    ) {
                        showsOverflowMenu = false
                        helpDialog = .information(
                            title: String(localized: "help", defaultValue: "Help"),
                            message: String(
                                localized: "help_ai_document_filter_text",
                                defaultValue: "Limit which Bibles, commentaries and other modules the AI agent can read. By default the AI sees all installed modules; filtering helps reduce noise and cost when you only want it to consider specific sources."
                            )
                        )
                    }
                }
            }
        }
        .task { load() }
        .aiConfigurationDialog($helpDialog, credentialStore: .keychain())
        .overlay {
            if let message = failureMessage {
                AndroidDecisionDialog(title: String(localized: "error", defaultValue: "Error"), message: message, actions: [
                    .init(id: "okay", title: String(localized: "okay", defaultValue: "OK"), style: .normal) { failureMessage = nil }
                ])
            }
        }
    }

    /** Returns Android's category header for one SWORD module group. */
    private func documentCategoryTitle(_ category: ModuleCategory) -> String {
        switch category {
        case .bible: return String(localized: "bible", defaultValue: "Bible")
        case .commentary: return String(localized: "doc_type_commentary", defaultValue: "Commentary")
        case .dictionary: return String(localized: "dictionary", defaultValue: "Dictionary")
        case .generalBook: return String(localized: "general_book", defaultValue: "Book")
        default: return category.rawValue
        }
    }

    /** Builds Android's full-width checked-is-allowed document row. */
    private func documentRow(_ document: ModuleInfo) -> some View {
        let isIncluded = !excludedDocuments.contains(document.name)
        return Button {
            if isIncluded {
                excludedDocuments.insert(document.name)
            } else {
                excludedDocuments.remove(document.name)
            }
        } label: {
            HStack(spacing: 12) {
                AndroidCheckboxIndicator(
                    isOn: isIncluded,
                    uncheckedColor: surfacePalette.secondaryForegroundColor,
                    accentColor: surfacePalette.controlAccentColor
                )
                Text("\(document.name) — \(document.description)")
                    .foregroundStyle(surfacePalette.foregroundColor)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /** Loads Android's global blacklist into explicit draft and baseline sets. */
    private func load() {
        installedDocuments = AIDocumentAccessInventory.installedModules(
            swordManager: swordManager
        )
        do {
            let value = try AISettingsStore(modelContext: modelContext).globalSettings().aiExcludedDocuments
            excludedDocuments = value
            initialExcludedDocuments = value
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Saves the document blacklist atomically and pops the destination. */
    private func saveAndClose() {
        do {
            let store = AISettingsStore(modelContext: modelContext)
            let settings = try store.globalSettings()
            settings.aiExcludedDocuments = excludedDocuments
            try store.save()
            performDismiss()
        } catch {
            failureMessage = String(localized: "error_occurred", defaultValue: "An error has occurred")
        }
    }

    /** Pops clean state immediately or asks before discarding dirty document choices. */
    private func requestClose() {
        if isDirty { showsDiscardConfirmation = true } else { performDismiss() }
    }

    /** Returns through the explicit Connection settings owner or environment fallback. */
    private func performDismiss() {
        if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }
}

/** Android `Books.installed()` projection shared by AI document-access presentation and tests. */
enum AIDocumentAccessInventory {
    /// Categories Android exposes in `AiDocumentFilterActivity`.
    private static let visibleCategories: Set<ModuleCategory> = [
        .bible, .commentary, .dictionary, .generalBook,
    ]

    /**
     Discovers and merges every document backend registered by the reader.

     - Parameter swordManager: Installed SWORD registry and module-root owner.
     - Returns: Android-visible SWORD and SQLite modules with SWORD-first initials precedence.
     - Side effects: Discovers MyBible, MySword, and e-Sword files below the module root.
     - Failure modes: Missing managers and malformed SQLite files yield only readable modules.
     */
    static func installedModules(swordManager: SwordManager?) -> [ModuleInfo] {
        guard let swordManager else { return [] }
        let sqliteModules = SQLiteDocumentModuleLibrary(
            moduleRootURL: URL(fileURLWithPath: swordManager.modulePath, isDirectory: true)
        ).modules.map(\.info)
        return merge(
            swordModules: swordManager.installedModules(),
            sqliteModules: sqliteModules
        )
    }

    /**
     Applies Android's installed-book category and duplicate-registration contract.

     - Parameters:
       - swordModules: Native SWORD modules registered first.
       - sqliteModules: Android SQLite modules registered afterward.
     - Returns: Visible documents in backend registration order with the first initials retained.
     - Side effects: None.
     - Failure modes: None; unsupported categories are omitted.
     */
    static func merge(
        swordModules: [ModuleInfo],
        sqliteModules: [ModuleInfo]
    ) -> [ModuleInfo] {
        var seenInitials = Set<String>()
        return (swordModules + sqliteModules).filter { module in
            visibleCategories.contains(module.category)
                && seenInitials.insert(module.name).inserted
        }
    }
}
