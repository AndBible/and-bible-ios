// LabelManagerView.swift -- Android Manage Labels WORKSPACE mode

import BibleCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Owns label-deletion preview and commit operations shared by Manage Labels and Label Edit.

 The full editor needs the exact bookmark-orphan preview before it can render Android's deletion
 choices. Both preview and mutation stay behind the canonical bookmark/workspace service boundary;
 the SwiftUI routes never detach relationships or edit live persistence objects themselves.
 */
enum LabelManagerMutation {
    /** Returns Android's deterministic orphan-bookmark deletion preview for one live label. */
    static func deletionImpact(
        for label: BibleCore.Label,
        in modelContext: ModelContext
    ) -> BookmarkLabelDeletionImpact? {
        BookmarkService(store: BookmarkStore(modelContext: modelContext))
            .labelDeletionImpact(id: label.id)
    }

    /** Deletes one label and applies the caller's explicit orphan-bookmark choice atomically. */
    @discardableResult
    static func deleteLabel(
        _ label: BibleCore.Label,
        deleteOrphanedBookmarks: Bool = false,
        in modelContext: ModelContext
    ) throws -> BookmarkLabelDeletionImpact {
        try WorkspaceLabelConfigurationService(modelContext: modelContext).deleteLabel(
            id: label.id,
            deleteOrphanedBookmarks: deleteOrphanedBookmarks
        )
    }
}

/**
 Presents Android `ManageLabels.Mode.WORKSPACE` as an app-owned activity.

 This route composes the same shared activity bar, Ab* search strip, Active/Recent/Other list
 projection, row controls, popup menu, Help content, full label editor, and Study Pad archive
 workflow used by the other Manage Labels modes. It deliberately contains no iOS `List`, toolbar,
 navigation link, sheet, context menu, swipe action, or feature-local color approximation.

 Data dependencies:
 - the complete Android label set and localized reserved-label presentation
 - the active workspace's auto-assignment, primary, recent-label, and override state
 - the reader/workspace-owned `ReaderThemeSurfacePalette`

 Side effects:
 - Back atomically commits favourite and workspace auto-assignment changes
 - full-editor Save commits complete label and workspace-override values through BibleCore
 - Reset clears workspace auto-assignment and label favourites after app-owned confirmation
 - overflow export/import delegates to the one shared Android Study Pad archive workflow

 Failure modes:
 - stale labels/workspaces, persistence journals, archives, and filesystem failures remain visible
   in app-owned dialogs; the route closes only after a successful Back or Reset commit
 */
public struct LabelManagerView: View {
    /** User-visible non-archive failure retained on the app-owned route. */
    private struct Feedback: Equatable {
        let title: String
        let message: String
    }

    /** Stable overflow anchor shared with the reusable popup presenter. */
    private enum PopupAnchor {
        static let overflow = "labelManagerOverflowAnchor"
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Complete label collection; Android WORKSPACE mode includes the Unlabelled system row.
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]

    /// Android's persisted Ab* versus *ab* search behavior for non-Study-Pad modes.
    @AppStorage("labels_list_filter_searchInsideTextButtonActive")
    private var searchesAnywhereInName = false

    /// Active workspace whose Manage Labels data is edited.
    private let workspace: Workspace?

    /// Reader/workspace-owned palette supplied by the route owner.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Parent route closure; standalone package callers fall back to environment dismissal.
    private let onDismiss: (() -> Void)?

    /// Complete unsaved WORKSPACE-mode state.
    @State private var autoAssignLabelIDs: Set<UUID> = []
    @State private var autoAssignPrimaryLabelID: UUID?
    @State private var recentLabelIDs: [UUID] = []
    @State private var favouriteValues: [UUID: Bool] = [:]
    @State private var workspaceOverrideModes: [UUID: Int] = [:]

    /// Android retains this mixed projection until search or explicit Reorder.
    @State private var visibleItems: [AndroidManageLabelListItem] = []
    @State private var searchText = ""
    @State private var hasLoaded = false
    @State private var isCommitting = false

    /// App-owned popup, dialog, and full-editor state.
    @State private var showsOverflowMenu = false
    @State private var showsHelp = false
    @State private var showsResetConfirmation = false
    @State private var newLabelDraft: AndroidLabelEditorDraft?
    @State private var editingLabelID: UUID?
    @State private var feedback: Feedback?

    /// Shared archive state used by Study Pads, Assignment, and Workspace modes.
    @State private var archiveWorkflow = AndroidStudyPadArchiveWorkflow()

    /**
     Creates a standalone Workspace Manage Labels route using the application palette.

     - Parameter workspace: Active workspace whose auto-assignment state is edited.
     - Side effects: none until task loading or user interaction.
     - Failure modes: none.
     */
    public init(workspace: Workspace? = nil) {
        self.workspace = workspace
        surfacePalette = .standard
        onDismiss = nil
    }

    /** Creates a reader-owned Workspace Manage Labels route with inherited palette and closure. */
    init(
        workspace: Workspace?,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: (() -> Void)?
    ) {
        self.workspace = workspace
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
    }

    /// Android's complete assignable set, including the Unlabelled system row in this mode.
    private var workspaceLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadExportLabels(from: allLabels)
    }

    /// Android's Study Pad export multiselect uses the same complete assignable set.
    private var exportLabels: [BibleCore.Label] {
        workspaceLabels
    }

    /// Query fingerprint used to reconcile full-editor and archive mutations.
    private var labelFingerprint: String {
        allLabels.map {
            "\($0.id.uuidString):\($0.name):\($0.favourite):\($0.customIcon ?? "")"
        }.joined(separator: "|")
    }

    /// Deterministic compact state consumed by UI automation without snapshot assumptions.
    private var labelManagerAccessibilityValue: String {
        let baseState = "count=\(workspaceLabels.count);showNewLabel=\(newLabelDraft != nil)"
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports else {
            return baseState
        }
        let rowTokens = workspaceLabels
            .prefix(UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
            .map { "|\(accessibilitySegment(AndroidLabelPresentation.displayName(for: $0)))|" }
            .joined(separator: ",")
        return "\(baseState);rows=\(rowTokens)"
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidManageLabelsActivityScreen(
            title: String(localized: "labels", defaultValue: "Labels"),
            appBarAccessibilityIdentifier: "labelManagerAppBar",
            surfacePalette: surfacePalette,
            onBack: commitAndClose,
            compactModeTitle: searchesAnywhereInName ? "*ab*" : "Ab*",
            localizedModeTitle: searchesAnywhereInName
                ? String(localized: "search_mode_name_contains", defaultValue: "Name (contains)")
                : String(localized: "search_mode_name_start", defaultValue: "Name (from start)"),
            isModeActive: searchesAnywhereInName,
            searchText: $searchText,
            accessibilityPrefix: "labelManager",
            onSelectSearchMode: {
                searchesAnywhereInName.toggle()
                rebuildVisibleItems()
            }
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityAddCircle"),
                accessibilityLabel: String(localized: "new_item", defaultValue: "New"),
                accessibilityIdentifier: "labelManagerAddButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: beginNewLabel
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("DrawerHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "labelManagerHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: {
                    showsOverflowMenu = false
                    showsHelp = true
                }
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ManageLabelsReorder"),
                accessibilityLabel: String(localized: "reorder", defaultValue: "Re-order"),
                accessibilityIdentifier: "labelManagerReorderButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: rebuildVisibleItems
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "labelManagerOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsOverflowMenu.toggle() }
            )
            .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } results: {
                labelList
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "labels", defaultValue: "Labels"),
                accessibilityIdentifier: "labelManagerScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .overlay(alignment: .topLeading) { labelManagerStateExport }
        .task(id: workspace?.id) { loadWorkspaceState() }
        .onChange(of: searchText) { _, _ in rebuildVisibleItems() }
        .onChange(of: labelFingerprint) { _, _ in reconcileLabelsAfterExternalMutation() }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 300,
            estimatedMenuHeight: 132,
            accessibilityIdentifier: "labelManagerOverflowMenu"
        ) {
            overflowMenu
        }
        .overlay { presentationLayer }
        .fileExporter(
            isPresented: Binding(
                get: { archiveWorkflow.showsFileExporter },
                set: { archiveWorkflow.showsFileExporter = $0 }
            ),
            document: archiveWorkflow.exportDocument,
            contentType: .zip,
            defaultFilename: archiveWorkflow.exportFileName,
            onCompletion: archiveWorkflow.handleFileExportCompletion
        )
        .fileImporter(
            isPresented: Binding(
                get: { archiveWorkflow.showsFileImporter },
                set: { archiveWorkflow.showsFileImporter = $0 }
            ),
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false,
            onCompletion: archiveWorkflow.handleFileImportSelection
        )
    }

    /// Shared Android category rows and compact editable label controls.
    private var labelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    switch item {
                    case .category(let category):
                        AndroidManageLabelCategoryRow(category: category, surfacePalette: surfacePalette)
                    case .label(let id):
                        if let label = allLabels.first(where: { $0.id == id }) {
                            workspaceRow(label)
                                .accessibilityIdentifier(
                                    "labelManagerRowButton-\(AndroidLabelPresentation.displayName(for: label))"
                                )
                        }
                    }
                    Divider().overlay(surfacePalette.inactiveBorderColor)
                }
            }
        }
        .overlay {
            if !hasLoaded || isCommitting {
                ProgressView()
                    .tint(surfacePalette.foregroundColor)
                    .accessibilityIdentifier("labelManagerProgress")
            }
        }
    }

    /// Binds one label to Android WORKSPACE mode without mutating its live SwiftData object.
    private func workspaceRow(_ label: BibleCore.Label) -> some View {
        let isUnlabelled = label.id == BibleCore.Label.unlabeledId
            || label.name == BibleCore.Label.unlabeledName
        return AndroidManageLabelRow(
            label: label,
            isSelected: autoAssignLabelIDs.contains(label.id),
            isFavourite: favouriteValue(for: label),
            isPrimary: autoAssignPrimaryLabelID == label.id,
            isAutoAssigned: autoAssignLabelIDs.contains(label.id),
            hasWorkspaceOverride: workspaceOverrideModes[label.id] != nil,
            showsAssignment: false,
            showsFavourite: !isUnlabelled,
            showsPrimary: !isUnlabelled,
            showsAutoAssign: !isUnlabelled,
            surfacePalette: surfacePalette,
            onEdit: { editingLabelID = label.id },
            onToggleAssignment: {},
            onToggleFavourite: { favouriteValues[label.id] = !favouriteValue(for: label) },
            onSelectPrimary: { autoAssignPrimaryLabelID = label.id },
            onToggleAutoAssign: { toggleAutoAssignment(label.id) }
        )
    }

    /// Global app-owned popup matching Android's Reset/Export/Import order.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "labelManagerOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(localized: "reset_generic", defaultValue: "Reset"),
                    accessibilityIdentifier: "labelManagerResetAction"
                ) {
                    showsOverflowMenu = false
                    showsResetConfirmation = true
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "export_something", defaultValue: "Export %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "labelManagerExportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginExport()
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "labelManagerImportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginImport()
                }
            }
        }
    }

    /// Full app-owned editors and dialogs, with one interactive presentation at a time.
    @ViewBuilder
    private var presentationLayer: some View {
        if let newLabelDraft {
            AndroidLabelEditorView(
                draft: newLabelDraft,
                workspace: workspace,
                surfacePalette: surfacePalette,
                initialWorkspaceConfiguration: WorkspaceLabelConfiguration(
                    isAutoAssigned: true,
                    isPrimaryAutoAssigned: true
                ),
                onSaved: handleEditorSave,
                onCancel: { self.newLabelDraft = nil }
            )
        } else if let editingLabelID,
                  let label = allLabels.first(where: { $0.id == editingLabelID }) {
            AndroidLabelEditorView(
                label: label,
                initialValues: editorValues(for: label),
                workspace: workspace,
                initialWorkspaceConfiguration: editorWorkspaceConfiguration(for: label),
                surfacePalette: surfacePalette,
                onSaved: handleEditorSave,
                onClose: { self.editingLabelID = nil }
            )
        } else if showsHelp {
            AndroidManageLabelsHelpDialog(mode: .workspace(isWindow: false)) {
                showsHelp = false
            }
        } else if showsResetConfirmation {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    localized: "reset_workspace_labels",
                    defaultValue: "Do you want to reset auto-assign and favorite settings for this workspace?"
                ),
                actions: [
                    .init(
                        id: "cancel",
                        title: String(localized: "cancel", defaultValue: "Cancel"),
                        style: .normal
                    ) { showsResetConfirmation = false },
                    .init(
                        id: "yes",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .normal
                    ) { resetAndClose() },
                ],
                accessibilityIdentifier: "labelManagerResetConfirmationDialog"
            )
        } else if archiveWorkflow.showsExportSelection {
            StudyPadExportSelectionDialog(
                labels: exportLabels,
                selectedLabelIDs: Binding(
                    get: { archiveWorkflow.exportLabelIDs },
                    set: { archiveWorkflow.exportLabelIDs = $0 }
                ),
                isExporting: archiveWorkflow.isExporting,
                onCancel: archiveWorkflow.dismissExportSelection,
                onExport: {
                    archiveWorkflow.exportSelectedStudyPads(
                        labels: exportLabels,
                        modelContainer: modelContext.container
                    )
                }
            )
        } else if let importInspection = archiveWorkflow.importInspection {
            StudyPadImportConfirmationDialog(
                summary: importInspection.summary,
                isImporting: archiveWorkflow.isImporting,
                onCancel: archiveWorkflow.dismissImportInspection,
                onImport: {
                    archiveWorkflow.applyImport(modelContext: modelContext) {
                        reconcileLabelsAfterExternalMutation()
                    }
                }
            )
        } else if let feedback {
            AndroidDecisionDialog(
                title: feedback.title,
                message: feedback.message,
                actions: [
                    .init(id: "ok", title: String(localized: "okay", defaultValue: "OK"), style: .normal) {
                        self.feedback = nil
                    },
                ],
                accessibilityIdentifier: "labelManagerFeedbackDialog"
            )
        } else if let archiveFeedback = archiveWorkflow.feedback {
            AndroidDecisionDialog(
                title: archiveFeedback.title,
                message: archiveFeedback.message,
                actions: [
                    .init(id: "ok", title: String(localized: "okay", defaultValue: "OK"), style: .normal) {
                        archiveWorkflow.feedback = nil
                    },
                ],
                accessibilityIdentifier: "labelManagerArchiveFeedbackDialog"
            )
        }
    }

    /// Compact hidden state probe used by UI tests instead of native-list assumptions.
    @ViewBuilder
    private var labelManagerStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(labelManagerAccessibilityValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("labelManagerStateExport")
                .accessibilityValue(labelManagerAccessibilityValue)
        }
    }

    /// Loads canonical workspace state without changing live SwiftData models.
    private func loadWorkspaceState() {
        guard !hasLoaded else { return }
        do {
            let snapshot = try WorkspaceLabelConfigurationService(modelContext: modelContext)
                .bookmarkLabelAssignmentSnapshot(bookmarkIDs: [], workspaceID: workspace?.id)
            autoAssignLabelIDs = snapshot.autoAssignLabelIDs
            autoAssignPrimaryLabelID = snapshot.autoAssignPrimaryLabelID
            recentLabelIDs = snapshot.recentLabelIDs
            refreshWorkspaceOverrides()
            hasLoaded = true
            rebuildVisibleItems()
        } catch {
            hasLoaded = true
            feedback = Feedback(
                title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                message: error.localizedDescription
            )
        }
    }

    /// Reconciles labels created, edited, deleted, or imported by child app-owned surfaces.
    private func reconcileLabelsAfterExternalMutation() {
        guard hasLoaded else { return }
        let liveIDs = Set(allLabels.map(\.id))
        autoAssignLabelIDs.formIntersection(liveIDs)
        favouriteValues = favouriteValues.filter { liveIDs.contains($0.key) }
        if autoAssignPrimaryLabelID.map({ !autoAssignLabelIDs.contains($0) }) == true {
            autoAssignPrimaryLabelID = orderedIDs(in: autoAssignLabelIDs).first
        }
        refreshWorkspaceOverrides()
        rebuildVisibleItems()
    }

    /// Reads workspace override markers from the canonical fidelity owner.
    private func refreshWorkspaceOverrides() {
        guard let workspace else {
            workspaceOverrideModes = [:]
            return
        }
        let service = WorkspaceLabelConfigurationService(modelContext: modelContext)
        workspaceOverrideModes = Dictionary(uniqueKeysWithValues: workspaceLabels.compactMap { label in
            service.configuration(for: label.id, in: workspace).overrideMode.map { (label.id, $0) }
        })
    }

    /// Rebuilds Android's shared mixed list after load, search, or explicit Reorder only.
    private func rebuildVisibleItems() {
        guard hasLoaded else { return }
        visibleItems = AndroidManageLabelsListProjection.items(
            labels: workspaceLabels,
            activeLabelIDs: autoAssignLabelIDs,
            recentLabelIDs: recentLabelIDs,
            alwaysVisibleLabelIDs: [],
            searchText: searchText,
            searchesAnywhereInName: searchesAnywhereInName
        )
    }

    /// Toggles auto-assignment and preserves Android's primary-within-selected invariant.
    private func toggleAutoAssignment(_ labelID: UUID) {
        if autoAssignLabelIDs.remove(labelID) != nil {
            if autoAssignPrimaryLabelID == labelID || autoAssignPrimaryLabelID == nil {
                autoAssignPrimaryLabelID = orderedIDs(in: autoAssignLabelIDs).first
            }
        } else {
            autoAssignLabelIDs.insert(labelID)
            if autoAssignPrimaryLabelID == nil { autoAssignPrimaryLabelID = labelID }
        }
    }

    /// Returns an unsaved favourite value or the persisted label fallback.
    private func favouriteValue(for label: BibleCore.Label) -> Bool {
        favouriteValues[label.id] ?? label.favourite
    }

    /// Builds editor values without discarding the parent session's favourite draft.
    private func editorValues(for label: BibleCore.Label) -> LabelEditValues {
        var values = LabelEditValues(label: label)
        values.favourite = favouriteValue(for: label)
        return values
    }

    /// Builds full editor workspace state from the current unsaved WORKSPACE session.
    private func editorWorkspaceConfiguration(for label: BibleCore.Label) -> WorkspaceLabelConfiguration {
        WorkspaceLabelConfiguration(
            isAutoAssigned: autoAssignLabelIDs.contains(label.id),
            isPrimaryAutoAssigned: autoAssignPrimaryLabelID == label.id,
            overrideMode: workspaceOverrideModes[label.id]
        )
    }

    /// Merges a complete full-editor Save result back into this retained Manage Labels generation.
    private func handleEditorSave(
        labelID: UUID,
        values: LabelEditValues,
        configuration: WorkspaceLabelConfiguration
    ) {
        favouriteValues[labelID] = values.favourite
        if configuration.isAutoAssigned || configuration.isPrimaryAutoAssigned {
            autoAssignLabelIDs.insert(labelID)
        } else {
            autoAssignLabelIDs.remove(labelID)
        }
        if configuration.isPrimaryAutoAssigned {
            autoAssignPrimaryLabelID = labelID
        } else if autoAssignPrimaryLabelID == labelID {
            autoAssignPrimaryLabelID = orderedIDs(in: autoAssignLabelIDs).first
        }
        if let overrideMode = configuration.overrideMode {
            workspaceOverrideModes[labelID] = overrideMode
        } else {
            workspaceOverrideModes.removeValue(forKey: labelID)
        }
        if newLabelDraft != nil {
            autoAssignLabelIDs.insert(labelID)
            autoAssignPrimaryLabelID = labelID
        }
        rebuildVisibleItems()
    }

    /// Creates Android's unsaved new-label draft with suggested search name and opaque color.
    private func beginNewLabel() {
        showsOverflowMenu = false
        let suggestedName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let red = UInt32.random(in: 0...254)
        let green = UInt32.random(in: 0...254)
        let blue = UInt32.random(in: 0...254)
        let color = Int(Int32(bitPattern: 0xFF000000 | red << 16 | green << 8 | blue))
        newLabelDraft = AndroidLabelEditorDraft(newLabelName: suggestedName, color: color)
    }

    /// Applies Android Reset semantics and closes only if the atomic commit succeeds.
    private func resetAndClose() {
        showsResetConfirmation = false
        autoAssignLabelIDs = []
        autoAssignPrimaryLabelID = nil
        favouriteValues = Dictionary(uniqueKeysWithValues: workspaceLabels.compactMap { label in
            guard label.id != BibleCore.Label.unlabeledId else { return nil }
            return (label.id, false)
        })
        commitAndClose()
    }

    /// Commits one complete WORKSPACE generation, then returns to the owning route.
    private func commitAndClose() {
        guard hasLoaded, !isCommitting else { return }
        isCommitting = true
        do {
            try WorkspaceLabelConfigurationService(modelContext: modelContext)
                .commitBookmarkLabelAssignment(
                    bookmarkIDs: [],
                    orderedSelectedLabelIDs: [],
                    primaryLabelID: nil,
                    favouriteValues: favouriteValues,
                    autoAssignLabelIDs: autoAssignLabelIDs,
                    autoAssignPrimaryLabelID: autoAssignPrimaryLabelID,
                    workspaceID: workspace?.id
                )
            isCommitting = false
            close()
        } catch {
            isCommitting = false
            feedback = Feedback(
                title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                message: error.localizedDescription
            )
        }
    }

    /// Stable Android-visible ordering used when repairing auto-assignment primary state.
    private func orderedIDs(in ids: Set<UUID>) -> [UUID] {
        workspaceLabels.map(\.id).filter(ids.contains)
    }

    /// Closes through the route owner or standalone environment dismissal.
    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

    /// Converts one label title to the historical compact UI-test state token format.
    private func accessibilitySegment(_ value: String) -> String {
        value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
