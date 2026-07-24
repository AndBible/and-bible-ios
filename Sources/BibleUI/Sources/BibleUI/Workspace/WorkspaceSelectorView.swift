// WorkspaceSelectorView.swift — App-owned Android workspace selection and management activity

import Foundation
import SwiftUI
import SwiftData
import BibleCore

/**
 Presents Android's complete Workspace Selector activity without native iOS list, toolbar, sheet,
 context-menu, or edit-mode presentation.

 The activity owns a searchable and reorderable staged data set, exact per-row overflow actions,
 selective settings-copy workflows, workspace Text Options routing, Help, and the persistent
 Dismiss/Save bar. Existing workspaces are not mutated until Save or an explicitly confirmed
 workspace switch, so Android's discard/apply behavior remains real instead of cosmetic.

 Data dependencies:
 - `windowManager` and `WorkspaceSelectionService` coordinate live/persisted activation
 - `WorkspaceStore` applies accepted create/clone/update/remove/order operations
 - `SettingsStore` owns global text-display settings used by selective copy and the parent route
 - `workspaces` supplies the initial SwiftData snapshot only; edits occur in value drafts

 Side effects:
 - Save applies staged workspace mutations and repairs active selection when needed
 - selecting a row activates it immediately when clean, or after Android's Apply changes decision
 - New creates and activates a workspace after resolving any existing staged edits
 - global settings-copy and Global Text Options update application settings immediately

 Failure modes:
 - missing persisted rows during commit are skipped rather than retargeting another workspace
 - removing the last draft is disabled, preserving a valid workspace graph
 */
public struct WorkspaceSelectorView: View {
    /// Live speech runtime stopped and rebound atomically when a workspace is selected.
    private let speakService: SpeakService?

    /// Reader/workspace palette that owns this activity and its child activities.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Explicit reader-destination dismissal, with environment dismissal as a standalone fallback.
    private let onDismiss: (() -> Void)?

    @Environment(WindowManager.self) private var windowManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Persisted workspaces used to seed drafts when the activity first attaches.
    @Query(sort: \Workspace.orderNumber) private var workspaces: [Workspace]

    /// Mutable Android activity data set; this is the only state changed before Save.
    @State private var drafts: [WorkspaceSelectorDraft] = []

    /// Initial activity snapshot used for deterministic dirty-state comparison.
    @State private var initialDrafts: [WorkspaceSelectorDraft] = []

    /// Prevents SwiftData query refreshes from replacing in-progress activity edits.
    @State private var hasLoadedDrafts = false

    /// Expanded Android toolbar search state.
    @State private var isSearchVisible = false

    /// Current name/summary filter.
    @State private var searchText = ""

    /// Workspace whose exact row overflow popup is visible.
    @State private var activeRowMenuID: UUID?

    /// Workspace row currently moved from Android's drag handle.
    @State private var draggedWorkspaceID: UUID?

    /// Selector-owned create, rename, or clone name prompt.
    @State private var workspacePrompt: WorkspaceNamePrompt?

    /// Draft shared with the active name prompt.
    @State private var workspacePromptName = ""

    /// App-owned workspace/global Text Options child route.
    @State private var settingsDestination: WorkspaceSelectorSettingsDestination?

    /// Global settings value used by the nested Global Text Options activity.
    @State private var globalDisplaySettings = TextDisplaySettings.appDefaults

    /// Whether Android's workspace-only Help dialog is visible.
    @State private var showsHelp = false

    /// Current stage of Android's selective settings-copy workflow.
    @State private var copyStage: WorkspaceSelectorCopyStage?

    /// Selected raw field identities shared by both copy stages.
    @State private var selectedCopyIDs: Set<String> = []

    /// Field identities retained while the second-stage target dialog is visible.
    @State private var copyFieldIDs: Set<String> = []

    /// Pending row/new-workspace target for Android's Apply changes decision.
    @State private var pendingActivation: WorkspaceSelectorPendingActivation?

    /**
     Creates the standalone selector using the standard application palette.

     - Parameter speakService: Optional live speech runtime to rebind on workspace activation.
     - Side effects: none during construction.
     - Failure modes: nil speech service preserves headless and preview callers.
     */
    public init(speakService: SpeakService? = nil) {
        self.speakService = speakService
        surfacePalette = .standard
        onDismiss = nil
    }

    /**
     Creates the reader-owned workspace activity with explicit palette and dismissal.

     - Parameters:
       - speakService: Reader speech runtime to checkpoint and rebind on activation.
       - surfacePalette: Workspace/window palette shared with the launching reader.
       - onDismiss: Explicit reader destination close command.
     - Side effects: none during construction.
     - Failure modes: none.
     */
    init(
        speakService: SpeakService?,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: @escaping () -> Void
    ) {
        self.speakService = speakService
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
    }

    /// Store used for grouped workspace graph mutations.
    private var workspaceStore: WorkspaceStore {
        WorkspaceStore(modelContext: modelContext)
    }

    /// Store used for active identity and global Text Options persistence.
    private var settingsStore: SettingsStore {
        SettingsStore(modelContext: modelContext)
    }

    /// Shared active-workspace coordinator used by selector commits and row activation.
    private var workspaceSelectionService: WorkspaceSelectionService {
        WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager,
            speakService: speakService
        )
    }

    /// Whether staged activity rows differ from the initial persisted snapshot.
    private var isDirty: Bool {
        drafts != initialDrafts
    }

    /// Draft rows matching Android's case-insensitive name/summary search.
    private var filteredDrafts: [WorkspaceSelectorDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return drafts }
        return drafts.filter { draft in
            draft.name.localizedCaseInsensitiveContains(query)
                || (draft.contentsText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Whether a dialog currently blocks the underlying activity.
    private var hasBlockingDialog: Bool {
        workspacePrompt != nil || showsHelp || copyStage != nil || pendingActivation != nil
    }

    /** Builds the selector or its app-owned Text Options child activity. */
    public var body: some View {
        Group {
            if let settingsDestination {
                settingsActivity(settingsDestination)
            } else {
                selectorActivity
            }
        }
        .onAppear(perform: loadDraftsIfNeeded)
    }

    /** Complete app-owned Workspace Selector activity. */
    private var selectorActivity: some View {
        AndroidActivityScreen(
            title: String(
                localized: "workspace_selector_title",
                defaultValue: "Select workspace"
            ),
            accessibilityIdentifier: "workspaceSelectorTopAppBar",
            palette: surfacePalette,
            onBack: discardAndClose
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivitySearch"),
                accessibilityLabel: String(localized: "search", defaultValue: "Search"),
                accessibilityIdentifier: "workspaceSelectorSearchButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: toggleSearch
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityAddCircle"),
                accessibilityLabel: String(localized: "new_item", defaultValue: "New"),
                accessibilityIdentifier: "workspaceSelectorAddButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: prepareCreate
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "workspaceSelectorHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsHelp = true }
            )
        } content: {
            VStack(spacing: 0) {
                if isSearchVisible {
                    workspaceSearchBar
                }

                workspaceList

                AndroidActivityCommitBar(
                    dismissTitle: String(localized: "dismiss", defaultValue: "Dismiss"),
                    commitTitle: String(localized: "save_and_exit", defaultValue: "Save"),
                    backgroundColor: surfacePalette.backgroundColor,
                    accentColor: surfacePalette.controlAccentColor,
                    disabledColor: surfacePalette.disabledForegroundColor,
                    isCommitEnabled: isDirty,
                    accessibilityPrefix: "workspaceSelector",
                    onDismiss: discardAndClose,
                    onCommit: saveAndClose
                )
            }
        }
        .androidAnchoredPopupMenu(
            anchorID: activeRowMenuID.map(rowMenuAnchorID) ?? "workspaceSelectorNoMenuAnchor",
            isPresented: rowMenuPresentationBinding,
            menuWidth: 270,
            estimatedMenuHeight: 292,
            accessibilityIdentifier: "workspaceSelectorRowMenu"
        ) {
            workspaceRowMenu
        }
        .androidAccessibilityIdentityMarker(
            label: String(localized: "workspace_selector_title", defaultValue: "Select workspace"),
            accessibilityIdentifier: "workspaceSelectorScreen",
            surfaceColor: surfacePalette.backgroundColor
        )
        .disabled(hasBlockingDialog)
        .overlay {
            selectorDialogOverlay
        }
    }

    /// Android toolbar search expansion rendered on the same owner palette.
    private var workspaceSearchBar: some View {
        HStack(spacing: 0) {
            AndroidActivityTextInput(
                placeholder: String(localized: "search", defaultValue: "Search"),
                text: $searchText,
                foregroundColor: surfacePalette.foregroundColor,
                backgroundColor: surfacePalette.controlFillColor,
                borderColor: surfacePalette.controlAccentColor,
                accessibilityIdentifier: "workspaceSelectorSearchField"
            )

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    AndBibleIconView(name: "ActivityClose", size: 22)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(surfacePalette.secondaryForegroundColor)
                .accessibilityLabel(String(localized: "clear", defaultValue: "Clear"))
                .accessibilityIdentifier("workspaceSelectorClearSearchButton")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(surfacePalette.backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(surfacePalette.inactiveBorderColor)
                .frame(height: 1)
        }
    }

    /// Android RecyclerView equivalent with explicit row dividers and drag targets.
    private var workspaceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filteredDrafts.isEmpty {
                    Text(
                        searchText.isEmpty
                            ? String(localized: "workspace_no_workspaces", defaultValue: "No workspaces")
                            : String(localized: "no_results", defaultValue: "No results")
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(surfacePalette.secondaryForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                } else {
                    ForEach(filteredDrafts) { draft in
                        workspaceRow(draft)
                            .onDrop(
                                of: [.text],
                                delegate: WorkspaceSelectorDropDelegate(
                                    targetID: draft.id,
                                    drafts: $drafts,
                                    draggedID: $draggedWorkspaceID,
                                    isEnabled: searchText.isEmpty
                                )
                            )

                        Divider()
                            .overlay(surfacePalette.inactiveBorderColor)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surfacePalette.backgroundColor)
    }

    /** Builds one Android `workspace_list_item` row. */
    private func workspaceRow(_ draft: WorkspaceSelectorDraft) -> some View {
        let isActive = draft.persistedID == windowManager.activeWorkspace?.id
        let displayName = workspaceDisplayName(draft)

        return HStack(spacing: 0) {
            AndBibleIconView(name: "MyDocumentDragHandle", size: 24)
                .foregroundStyle(Color(argbInt: draft.workspaceColor ?? Workspace.defaultWorkspaceColor))
                .frame(width: 60)
                .frame(minHeight: 66)
                .contentShape(Rectangle())
                .opacity(searchText.isEmpty ? 1 : 0)
                .allowsHitTesting(searchText.isEmpty)
                .onDrag {
                    draggedWorkspaceID = draft.id
                    return NSItemProvider(object: draft.id.uuidString as NSString)
                }
                .accessibilityLabel(String(localized: "reorder", defaultValue: "Reorder"))
                .accessibilityIdentifier("workspaceSelectorDragHandle::\(draft.id.uuidString)")

            Button {
                requestActivation(of: draft)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeWorkspaceTitle(displayName, isActive: isActive))
                        .font(.system(size: 18, weight: isActive ? .bold : .regular))
                        .foregroundStyle(surfacePalette.foregroundColor)
                        .lineLimit(1)

                    if let summary = draft.contentsText, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 14))
                            .foregroundStyle(surfacePalette.secondaryForegroundColor)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspaceSelectorRowButton")
            .accessibilityLabel(displayName)
            .accessibilityValue(isActive ? "activeWorkspace" : "inactiveWorkspace")

            Button {
                activeRowMenuID = activeRowMenuID == draft.id ? nil : draft.id
            } label: {
                AndBibleIconView(name: "ToolbarOverflow", size: 24)
                    .frame(width: 45)
                    .frame(minHeight: 66)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .androidPopupMenuAnchor(id: rowMenuAnchorID(draft.id))
            .accessibilityLabel(
                String(
                    localized: "more_options_for",
                    defaultValue: "More options for \(displayName)"
                )
            )
            .accessibilityIdentifier("workspaceSelectorMenuButton")
        }
        .background(isActive ? surfacePalette.controlFillColor : surfacePalette.backgroundColor)
        .accessibilityElement(children: .contain)
    }

    /// Shared Android popup surface for the currently selected row.
    @ViewBuilder
    private var workspaceRowMenu: some View {
        if let draftID = activeRowMenuID,
           let draft = drafts.first(where: { $0.id == draftID }) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "workspaceSelectorRowMenuSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    workspaceMenuRow(
                        title: String(localized: "delete_workspace", defaultValue: "Remove"),
                        identifier: "workspaceSelectorDeleteAction",
                        draft: draft,
                        isEnabled: drafts.count > 1,
                        action: removeDraft
                    )
                    workspaceMenuRow(
                        title: String(localized: "rename", defaultValue: "Rename"),
                        identifier: "workspaceSelectorRenameAction",
                        draft: draft,
                        action: prepareRename
                    )
                    workspaceMenuRow(
                        title: String(localized: "new_copied_workspace", defaultValue: "Copy as new"),
                        identifier: "workspaceSelectorCloneAction",
                        draft: draft,
                        action: prepareClone
                    )
                    workspaceMenuRow(
                        title: String(localized: "workspace_settings", defaultValue: "Settings…"),
                        identifier: "workspaceSelectorSettingsAction",
                        draft: draft,
                        action: openWorkspaceSettings
                    )
                    workspaceMenuRow(
                        title: String(localized: "copy_workspace_settings", defaultValue: "Copy settings…"),
                        identifier: "workspaceSelectorCopySettingsAction",
                        draft: draft,
                        action: beginCopyToWorkspaces
                    )
                    workspaceMenuRow(
                        title: String(localized: "copy_settings_to_global", defaultValue: "Copy settings to global"),
                        identifier: "workspaceSelectorCopySettingsToGlobalAction",
                        draft: draft,
                        action: beginCopyToGlobal
                    )
                }
            }
        }
    }

    /** Builds one exact row in Android's `workspace_popup_menu`. */
    private func workspaceMenuRow(
        title: String,
        identifier: String,
        draft: WorkspaceSelectorDraft,
        isEnabled: Bool = true,
        action: @escaping (WorkspaceSelectorDraft) -> Void
    ) -> some View {
        AndroidPopupMenuRow(
            title: title,
            accessibilityIdentifier: identifier,
            isEnabled: isEnabled
        ) {
            activeRowMenuID = nil
            action(draft)
        }
        .accessibilityLabel(workspaceDisplayName(draft))
    }

    /// App-owned dialogs displayed above the disabled selector activity.
    @ViewBuilder
    private var selectorDialogOverlay: some View {
        if let prompt = workspacePrompt {
            WorkspaceNamePromptView(
                prompt: prompt,
                name: $workspacePromptName,
                onCancel: dismissWorkspacePrompt,
                onConfirm: { submitWorkspacePrompt(prompt) }
            )
        } else if showsHelp {
            AndroidHelpDialog(topics: [.workspaces], showsVersion: false) {
                showsHelp = false
            }
        } else if let copyStage {
            copyDialog(copyStage)
        } else if pendingActivation != nil {
            applyChangesDecisionDialog
        }
    }

    /** Android selective-copy dialog for fields or target workspaces. */
    private func copyDialog(_ stage: WorkspaceSelectorCopyStage) -> some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "workspaceSelectorCopyDialog",
            onOutsideTap: cancelCopyWorkflow
        ) {
            AndroidMultiselectDialogContent(
                title: copyDialogTitle(stage),
                rows: copyDialogRows(stage),
                selectedIDs: $selectedCopyIDs,
                isBusy: false,
                accessibilityIdentifier: "workspaceSelectorCopyDialogContent",
                accessibilityPrefix: "workspaceSelectorCopy",
                onCancel: cancelCopyWorkflow,
                onConfirm: { selectedIDs in
                    advanceCopyWorkflow(stage, selectedIDs: selectedIDs)
                }
            )
        }
    }

    /// Android Yes/No/Cancel prompt shown before activating with dirty drafts.
    private var applyChangesDecisionDialog: some View {
        AndroidDecisionDialog(
            title: "",
            message: String(
                localized: "workspace_save_changes",
                defaultValue: "Apply changes to workspaces?"
            ),
            actions: [
                .init(
                    id: "cancel",
                    title: String(localized: "cancel", defaultValue: "Cancel"),
                    style: .normal,
                    placement: .neutral,
                    perform: { pendingActivation = nil }
                ),
                .init(
                    id: "no",
                    title: String(localized: "no", defaultValue: "No"),
                    style: .normal,
                    perform: activateAfterDiscardingChanges
                ),
                .init(
                    id: "yes",
                    title: String(localized: "yes", defaultValue: "Yes"),
                    style: .normal,
                    perform: activateAfterApplyingChanges
                ),
            ],
            accessibilityIdentifier: "workspaceSelectorApplyChangesDialog"
        )
    }

    /** Builds workspace/global Text Options without native navigation presentation. */
    @ViewBuilder
    private func settingsActivity(_ destination: WorkspaceSelectorSettingsDestination) -> some View {
        switch destination {
        case .workspace(let draftID):
            if let draft = drafts.first(where: { $0.id == draftID }) {
                TextDisplaySettingsView(
                    settings: textDisplaySettingsBinding(for: draftID),
                    workspaceColor: workspaceColorBinding(for: draftID),
                    navigationTitle: String.localizedStringWithFormat(
                        String(
                            localized: "workspace_text_display_settings_title",
                            defaultValue: "Text options - %@"
                        ),
                        workspaceDisplayName(draft)
                    ),
                    scope: .workspace,
                    workspaceName: workspaceDisplayName(draft),
                    surfacePalette: surfacePalette,
                    onBack: { settingsDestination = nil },
                    onOpenGlobalSettings: {
                        globalDisplaySettings = settingsStore.globalTextDisplaySettings()
                        settingsDestination = .global(returningTo: draftID)
                    }
                )
            } else {
                Color.clear.onAppear { settingsDestination = nil }
            }
        case .global(let returningDraftID):
            TextDisplaySettingsView(
                settings: $globalDisplaySettings,
                workspaceColor: workspaceColorBinding(for: returningDraftID),
                navigationTitle: String(
                    localized: "global_text_display_settings_title",
                    defaultValue: "Global text options"
                ),
                scope: .global,
                workspaceName: drafts.first(where: { $0.id == returningDraftID }).map(workspaceDisplayName),
                surfacePalette: surfacePalette,
                onBack: { settingsDestination = .workspace(returningDraftID) },
                onChange: { settingsStore.setGlobalTextDisplaySettings(globalDisplaySettings) }
            )
        }
    }

    /// Presents or clears Android's toolbar search UI.
    private func toggleSearch() {
        isSearchVisible.toggle()
        if !isSearchVisible { searchText = "" }
        activeRowMenuID = nil
    }

    /// Seeds activity drafts and global parent settings once per presentation.
    private func loadDraftsIfNeeded() {
        guard !hasLoadedDrafts else { return }
        let loaded = workspaces.map(WorkspaceSelectorDraft.init(workspace:))
        drafts = loaded
        initialDrafts = loaded
        globalDisplaySettings = settingsStore.globalTextDisplaySettings()
        hasLoadedDrafts = true
    }

    /** Requests activation immediately when clean or through Android's decision when dirty. */
    private func requestActivation(of draft: WorkspaceSelectorDraft) {
        activeRowMenuID = nil
        if isDirty {
            pendingActivation = .draft(draft.id)
        } else if let workspace = persistedWorkspace(for: draft) {
            activateAndClose(workspace)
        }
    }

    /// Prepares Android's default new-workspace name.
    private func prepareCreate() {
        activeRowMenuID = nil
        workspacePromptName = String.localizedStringWithFormat(
            String(localized: "workspace_number", defaultValue: "Workspace %d"),
            drafts.count + 1
        )
        workspacePrompt = .create
    }

    /// Prepares Android's rename prompt for one exact draft identity.
    private func prepareRename(_ draft: WorkspaceSelectorDraft) {
        workspacePromptName = draft.name
        workspacePrompt = .rename(draft.id)
    }

    /// Prepares Android's Copy as new prompt for one exact draft identity.
    private func prepareClone(_ draft: WorkspaceSelectorDraft) {
        workspacePromptName = String.localizedStringWithFormat(
            String(localized: "copy_of_workspace", defaultValue: "Copy of %@"),
            workspaceDisplayName(draft)
        )
        workspacePrompt = .clone(draft.id)
    }

    /// Clears selector-owned name-prompt state without mutating drafts.
    private func dismissWorkspacePrompt() {
        workspacePrompt = nil
        workspacePromptName = ""
    }

    /** Commits one name prompt into staged state or a confirmed new-workspace activation. */
    private func submitWorkspacePrompt(_ prompt: WorkspaceNamePrompt) {
        let name = workspacePromptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        dismissWorkspacePrompt()

        switch prompt {
        case .create:
            if isDirty {
                pendingActivation = .newWorkspace(name: name)
            } else {
                createActivateAndClose(named: name)
            }
        case .rename(let draftID):
            updateDraft(id: draftID) { $0.name = name }
        case .clone(let draftID):
            guard let source = drafts.first(where: { $0.id == draftID }),
                  let index = drafts.firstIndex(where: { $0.id == draftID }) else {
                return
            }
            drafts.insert(WorkspaceSelectorDraft(cloning: source, name: name), at: index + 1)
        }
    }

    /// Stages removal while preserving Android's cannot-delete-final-workspace rule.
    private func removeDraft(_ draft: WorkspaceSelectorDraft) {
        guard drafts.count > 1 else { return }
        drafts.removeAll { $0.id == draft.id }
    }

    /// Opens workspace-scoped Text Options for a staged row.
    private func openWorkspaceSettings(_ draft: WorkspaceSelectorDraft) {
        settingsDestination = .workspace(draft.id)
    }

    /// Starts Android's field-then-workspace selective copy workflow.
    private func beginCopyToWorkspaces(_ draft: WorkspaceSelectorDraft) {
        selectedCopyIDs = []
        copyFieldIDs = []
        copyStage = .fieldsToWorkspaces(sourceID: draft.id)
    }

    /// Starts Android's field selection for copying to global defaults.
    private func beginCopyToGlobal(_ draft: WorkspaceSelectorDraft) {
        selectedCopyIDs = []
        copyFieldIDs = []
        copyStage = .fieldsToGlobal(sourceID: draft.id)
    }

    /// Clears every temporary copy-workflow value.
    private func cancelCopyWorkflow() {
        copyStage = nil
        selectedCopyIDs = []
        copyFieldIDs = []
    }

    /** Advances or commits Android's selective copy workflow. */
    private func advanceCopyWorkflow(_ stage: WorkspaceSelectorCopyStage, selectedIDs: [String]) {
        switch stage {
        case .fieldsToWorkspaces(let sourceID):
            copyFieldIDs = Set(selectedIDs)
            copyStage = .targetWorkspaces(sourceID: sourceID)
            selectedCopyIDs = []
        case .targetWorkspaces(let sourceID):
            copySelectedFields(from: sourceID, to: selectedIDs.compactMap(UUID.init(uuidString:)))
            cancelCopyWorkflow()
        case .fieldsToGlobal(let sourceID):
            copyFieldIDs = Set(selectedIDs)
            copySelectedFieldsToGlobal(from: sourceID)
            cancelCopyWorkflow()
        }
    }

    /// Localized title for the active Android multiselect stage.
    private func copyDialogTitle(_ stage: WorkspaceSelectorCopyStage) -> String {
        switch stage {
        case .fieldsToWorkspaces, .fieldsToGlobal:
            String(localized: "copy_settings_title", defaultValue: "Which settings do you want to copy?")
        case .targetWorkspaces:
            String(
                localized: "copy_settings_workspaces_title",
                defaultValue: "To which workspaces do you want to copy settings?"
            )
        }
    }

    /// Ordered rows matching Android's TextDisplaySettings Types or workspace order.
    private func copyDialogRows(_ stage: WorkspaceSelectorCopyStage) -> [AndroidMultiselectDialogRow<String>] {
        switch stage {
        case .fieldsToWorkspaces, .fieldsToGlobal:
            TextDisplaySettingsCopyField.allCases.map { field in
                AndroidMultiselectDialogRow(
                    id: field.rawValue,
                    title: field.title,
                    accessibilityIdentifier: "workspaceSelectorCopyField::\(field.rawValue)"
                )
            }
        case .targetWorkspaces(let sourceID):
            drafts.map { draft in
                AndroidMultiselectDialogRow(
                    id: draft.id.uuidString,
                    title: workspaceDisplayName(draft),
                    isEnabled: draft.id != sourceID,
                    accessibilityIdentifier: "workspaceSelectorCopyTarget::\(draft.id.uuidString)"
                )
            }
        }
    }

    /** Copies selected text-setting fields from one draft to target drafts. */
    private func copySelectedFields(from sourceID: UUID, to targetIDs: [UUID]) {
        guard let source = drafts.first(where: { $0.id == sourceID }) else { return }
        let sourceSettings = source.textDisplaySettings ?? TextDisplaySettings()
        let fields = selectedCopyFields
        let targets = Set(targetIDs)
        for index in drafts.indices where targets.contains(drafts[index].id) {
            let target = drafts[index].textDisplaySettings ?? TextDisplaySettings()
            drafts[index].textDisplaySettings = target.copyingSelectedFields(
                from: sourceSettings,
                fields: fields
            )
        }
    }

    /** Copies selected fields from one workspace draft into application defaults. */
    private func copySelectedFieldsToGlobal(from sourceID: UUID) {
        guard let source = drafts.first(where: { $0.id == sourceID }) else { return }
        let sourceSettings = source.textDisplaySettings ?? TextDisplaySettings()
        let updated = settingsStore.globalTextDisplaySettings().copyingSelectedFields(
            from: sourceSettings,
            fields: selectedCopyFields
        )
        globalDisplaySettings = updated
        settingsStore.setGlobalTextDisplaySettings(updated)
    }

    /// Selected copy fields reconstructed from their stable raw identities.
    private var selectedCopyFields: Set<TextDisplaySettingsCopyField> {
        Set(copyFieldIDs.compactMap(TextDisplaySettingsCopyField.init(rawValue:)))
    }

    /// Applies drafts, then activates the pending target and closes the activity.
    private func activateAfterApplyingChanges() {
        guard let pendingActivation else { return }
        self.pendingActivation = nil
        let resolved = applyDrafts()
        activate(pendingActivation, resolvedDrafts: resolved)
    }

    /// Discards drafts, then activates the pending persisted/new target and closes the activity.
    private func activateAfterDiscardingChanges() {
        guard let pendingActivation else { return }
        self.pendingActivation = nil
        activate(pendingActivation, resolvedDrafts: [:])
    }

    /** Resolves one pending activation after applying or discarding drafts. */
    private func activate(
        _ target: WorkspaceSelectorPendingActivation,
        resolvedDrafts: [UUID: Workspace]
    ) {
        switch target {
        case .draft(let draftID):
            if let workspace = resolvedDrafts[draftID]
                ?? drafts.first(where: { $0.id == draftID }).flatMap(persistedWorkspace) {
                activateAndClose(workspace)
            }
        case .newWorkspace(let name):
            createActivateAndClose(named: name)
        }
    }

    /// Applies staged changes and exits through the explicit owner route.
    private func saveAndClose() {
        _ = applyDrafts()
        closeActivity()
    }

    /// Discards all value drafts by closing without persistence.
    private func discardAndClose() {
        closeActivity()
    }

    /**
     Applies the full staged data set as one logical workspace activity commit.

     Existing rows are updated first, clones are deep-created before source removals, deletions use
     `WorkspaceSelectionService` so active state is repaired, and final order is persisted last.

     - Returns: A map from selector draft identity to its resolved persisted workspace.
     - Side effects: Mutates and saves workspace graphs and may repair active workspace selection.
     - Failure modes: Missing source rows are skipped; surviving rows still commit in order.
     */
    @discardableResult
    private func applyDrafts() -> [UUID: Workspace] {
        let store = workspaceStore
        let selection = workspaceSelectionService
        let originalWorkspaces = store.workspaces()
        var resolved: [UUID: Workspace] = [:]

        for draft in drafts {
            guard case .persisted(let workspaceID) = draft.origin,
                  let workspace = store.workspace(id: workspaceID) else {
                continue
            }
            apply(draft, to: workspace)
            resolved[draft.id] = workspace
        }
        store.persistChanges()

        for draft in drafts {
            guard case .clone(let sourceID) = draft.origin,
                  let source = store.workspace(id: sourceID) else {
                continue
            }
            let clone = store.cloneWorkspace(source, newName: draft.name)
            apply(draft, to: clone)
            resolved[draft.id] = clone
        }
        store.persistChanges()

        let retainedPersistedIDs = Set(drafts.compactMap(\.persistedID))
        let removed = originalWorkspaces.filter { !retainedPersistedIDs.contains($0.id) }
        if !removed.isEmpty {
            _ = selection.deleteWorkspaces(removed)
        }

        let finalOrder = drafts.compactMap { resolved[$0.id] }
        if !finalOrder.isEmpty {
            store.reorderWorkspaces(finalOrder)
        }
        return resolved
    }

    /// Copies staged scalar/settings fields onto a resolved persisted graph owner.
    private func apply(_ draft: WorkspaceSelectorDraft, to workspace: Workspace) {
        workspace.name = draft.name
        workspace.contentsText = draft.contentsText
        workspace.textDisplaySettings = draft.textDisplaySettings
        workspace.workspaceColor = draft.workspaceColor ?? Workspace.defaultWorkspaceColor
    }

    /// Creates a new workspace from the current active defaults, activates it, and exits.
    private func createActivateAndClose(named name: String) {
        let workspace = workspaceStore.createWorkspace(
            name: name,
            inheritingDefaultsFrom: windowManager.activeWorkspace
        )
        activateAndClose(workspace)
    }

    /// Activates one persisted workspace and closes the selector activity.
    private func activateAndClose(_ workspace: Workspace) {
        workspaceSelectionService.activate(workspace)
        closeActivity()
    }

    /// Resolves an existing persisted draft without accepting staged scalar changes.
    private func persistedWorkspace(for draft: WorkspaceSelectorDraft) -> Workspace? {
        draft.persistedID.flatMap(workspaceStore.workspace(id:))
    }

    /// Calls the reader destination owner or standalone environment dismiss action.
    private func closeActivity() {
        if let onDismiss { onDismiss() }
        else { dismiss() }
    }

    /// Mutates one exact draft without index assumptions after filtering/reordering.
    private func updateDraft(id: UUID, mutation: (inout WorkspaceSelectorDraft) -> Void) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        mutation(&drafts[index])
    }

    /// Mutable binding for one draft's workspace-scoped Text Options.
    private func textDisplaySettingsBinding(for draftID: UUID) -> Binding<TextDisplaySettings> {
        Binding(
            get: {
                drafts.first(where: { $0.id == draftID })?.textDisplaySettings
                    ?? TextDisplaySettings()
            },
            set: { value in
                updateDraft(id: draftID) { $0.textDisplaySettings = value }
            }
        )
    }

    /// Mutable binding for one draft's Android workspace color.
    private func workspaceColorBinding(for draftID: UUID) -> Binding<Int?> {
        Binding(
            get: { drafts.first(where: { $0.id == draftID })?.workspaceColor },
            set: { value in
                updateDraft(id: draftID) {
                    $0.workspaceColor = value ?? Workspace.defaultWorkspaceColor
                }
            }
        )
    }

    /// User-visible workspace name with Android's untitled fallback for malformed legacy rows.
    private func workspaceDisplayName(_ draft: WorkspaceSelectorDraft) -> String {
        draft.name.isEmpty ? String(localized: "untitled", defaultValue: "Untitled") : draft.name
    }

    /// Android current-workspace title format.
    private func activeWorkspaceTitle(_ name: String, isActive: Bool) -> String {
        guard isActive else { return name }
        return String.localizedStringWithFormat(
            String(localized: "workspace_listing_with_current", defaultValue: "%@ (current)"),
            name
        )
    }

    /// Stable anchor identity for one row's app-owned popup.
    private func rowMenuAnchorID(_ draftID: UUID) -> String {
        "workspaceSelectorRowMenuAnchor::\(draftID.uuidString)"
    }

    /// Converts optional row identity into the shared popup visibility binding.
    private var rowMenuPresentationBinding: Binding<Bool> {
        Binding(
            get: { activeRowMenuID != nil },
            set: { isPresented in
                if !isPresented { activeRowMenuID = nil }
            }
        )
    }
}

/// Selector-owned workspace name prompt operation.
private enum WorkspaceNamePrompt: Equatable {
    case create
    case rename(UUID)
    case clone(UUID)

    /// Android uses one shared title for create, rename, and clone name entry.
    var title: String {
        String(
            localized: "give_name_workspace",
            defaultValue: "Give name for new workspace"
        )
    }
}

/**
 Thin semantic wrapper around the shared Android dialog window and dialog text input.

 The wrapper retains established workspace automation identifiers and keyboard focus while shared
 components own the scrim, AppCompat palette, field chrome, geometry, and actions. It therefore
 does not recreate a feature-local modal card or invoke a native iOS alert/sheet.
 */
private struct WorkspaceNamePromptView: View {
    @Environment(\.colorScheme) private var colorScheme

    let prompt: WorkspaceNamePrompt
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var isNameFieldFocused: Bool

    /// Whether the prompt has a non-blank name Android can persist.
    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "workspaceNamePromptScreen",
            onOutsideTap: onCancel
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text(prompt.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

                AndroidDialogTextInput(
                    placeholder: String(localized: "name", defaultValue: "Name"),
                    text: $name,
                    colorScheme: colorScheme,
                    isMultiline: false,
                    accessibilityIdentifier: "workspaceNamePromptTextField"
                )
                .focused($isNameFieldFocused)
                .onSubmit {
                    guard canConfirm else { return }
                    onConfirm()
                }

                HStack(spacing: 20) {
                    Spacer()
                    Button(String(localized: "cancel", defaultValue: "Cancel"), action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
                        .accessibilityIdentifier("workspaceNamePromptCancelButton")
                    Button(String(localized: "okay", defaultValue: "OK"), action: onConfirm)
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(
                            canConfirm
                                ? AndroidDialogSurfacePalette.accent(for: colorScheme)
                                : AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
                        )
                        .disabled(!canConfirm)
                        .accessibilityIdentifier("workspaceNamePromptConfirmButton")
                }
            }
            .padding(22)
            .frame(maxWidth: 480)
        }
        .onAppear { isNameFieldFocused = true }
        .task(id: prompt) {
            await Task.yield()
            isNameFieldFocused = true
        }
    }
}
