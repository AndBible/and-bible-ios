// LabelAssignmentView.swift -- Android Manage Labels ASSIGN mode

import BibleCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Presents Android `ManageLabels.Mode.ASSIGN` as an app-owned activity.

 The route uses the shared Manage Labels app bar, search strip, category rows, label rows, popup,
 help dialog, full label editor, and Study Pad archive services. It initializes selection from the
 union of every requested Bible/generic bookmark and commits the complete draft only when Android's
 Up/Back action is used. No iOS List, toolbar, sheet, context menu, or immediate per-row database
 mutation participates in presentation.

 Data dependencies:
 - queried Android label models and localized presentation names
 - `WorkspaceLabelConfigurationService` for atomic bookmark/workspace persistence
 - owner-provided reader/workspace palette

 Side effects:
 - Back commits one exact label set to every selected bookmark plus favourite/workspace edits
 - label editor Save commits complete label values through the shared service
 - overflow export/import uses the canonical Android Study Pad archive service

 Failure modes:
 - stale bookmark, label, workspace, archive, and journal failures remain visible in an app-owned
   dialog without dismissing or partially applying this assignment draft
 */
struct LabelAssignmentView: View {
    /// Feedback payload rendered by the shared decision dialog.
    private struct Feedback: Equatable {
        let title: String
        let message: String
    }

    /// Shared Android overflow anchor identity.
    private enum PopupAnchor {
        static let overflow = "labelAssignmentOverflowAnchor"
    }

    /// Bible and generic bookmark identities receiving the exact selected-label set.
    private let bookmarkIDs: [UUID]

    /// Active workspace whose auto-assignment state is edited with this route.
    private let workspace: Workspace?

    /// Reader/workspace-owned palette; feature-local screenshot colors are forbidden.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Parent-owned close action.
    private let onDismiss: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Complete persisted label collection, including Android system labels.
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]

    /// Android's non-Study-Pad search-mode preference.
    @AppStorage("labels_list_filter_searchInsideTextButtonActive")
    private var searchesAnywhereInName = false

    /// Draft state loaded from the canonical cross-category service.
    @State private var selectedLabelIDs: Set<UUID> = []
    @State private var primaryLabelID: UUID?
    @State private var autoAssignLabelIDs: Set<UUID> = []
    @State private var autoAssignPrimaryLabelID: UUID?
    @State private var recentLabelIDs: [UUID] = []
    @State private var favouriteValues: [UUID: Bool] = [:]
    @State private var workspaceOverrideModes: [UUID: Int] = [:]

    /// Android list population is retained until search/reorder, matching `updateLabelList()`.
    @State private var visibleItems: [AndroidManageLabelListItem] = []
    @State private var searchText = ""
    @State private var hasLoaded = false
    @State private var isCommitting = false

    /// App-owned popup/dialog/editor presentation state.
    @State private var showsOverflowMenu = false
    @State private var showsHelp = false
    @State private var newLabelDraft: AndroidLabelEditorDraft?
    @State private var editingLabelID: UUID?
    @State private var feedback: Feedback?

    /// Shared Study Pad archive state machine used by every Android Manage Labels mode.
    @State private var archiveWorkflow = AndroidStudyPadArchiveWorkflow()

    /** Creates Android assignment for one bookmark while preserving the historical call shape. */
    init(
        bookmarkId: UUID,
        workspace: Workspace? = nil,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onDismiss: (() -> Void)? = nil
    ) {
        bookmarkIDs = [bookmarkId]
        self.workspace = workspace
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
    }

    /**
     Creates Android assignment for a multi-bookmark contextual selection.

     - Parameters:
       - bookmarkIDs: Bible and generic identities whose label union seeds the route.
       - workspace: Active workspace carrying recent/auto-assignment state.
       - surfacePalette: Active reader/workspace palette.
       - onDismiss: Parent route close action after a successful commit.
     - Side effects: none until task loading or user interaction.
     - Failure modes: stale identities are surfaced after task loading.
     */
    init(
        bookmarkIDs: [UUID],
        workspace: Workspace? = nil,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: (() -> Void)? = nil
    ) {
        self.bookmarkIDs = bookmarkIDs
        self.workspace = workspace
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
    }

    /// Android assignment rows include every assignable label except synthetic Unlabelled.
    private var assignableLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadSelectorLabels(from: allLabels)
    }

    /// Android Study Pad export retains Unlabelled as an explicit export choice.
    private var exportLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadExportLabels(from: allLabels)
    }

    /// Stable label identity fingerprint used to reconcile editor/import changes.
    private var labelFingerprint: String {
        allLabels.map {
            "\($0.id.uuidString):\($0.name):\($0.favourite):\($0.customIcon ?? "")"
        }.joined(separator: "|")
    }

    /**
     Renders the complete assignment activity while exporting route identity beside its controls.

     The sibling marker keeps XCTest and assistive technology able to identify the destination
     without replacing the shared Manage Labels identifiers on search, assignment, edit, and
     app-bar controls.

     - Returns: One app-owned Android assignment activity and its noninteractive route marker.
     - Side effects: Loads the current assignment draft and responds to search/import mutations.
     - Failure modes: Loading and archive failures remain visible through app-owned dialogs.
     */
    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidManageLabelsActivityScreen(
                title: String(localized: "assign_labels", defaultValue: "Assign labels"),
                appBarAccessibilityIdentifier: "labelAssignmentAppBar",
                surfacePalette: surfacePalette,
                onBack: commitAndClose,
                compactModeTitle: searchesAnywhereInName ? "*ab*" : "Ab*",
                localizedModeTitle: searchesAnywhereInName
                    ? String(localized: "search_mode_name_contains", defaultValue: "Name (contains)")
                    : String(localized: "search_mode_name_start", defaultValue: "Name (from start)"),
                isModeActive: searchesAnywhereInName,
                searchText: $searchText,
                accessibilityPrefix: "labelAssignment",
                onSelectSearchMode: {
                    searchesAnywhereInName.toggle()
                    rebuildVisibleItems()
                }
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(localized: "new_item", defaultValue: "New"),
                    accessibilityIdentifier: "labelAssignmentAddButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: beginNewLabel
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DrawerHelp"),
                    accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                    accessibilityIdentifier: "labelAssignmentHelpButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: {
                        showsOverflowMenu = false
                        showsHelp = true
                    }
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ManageLabelsReorder"),
                    accessibilityLabel: String(localized: "reorder", defaultValue: "Re-order"),
                    accessibilityIdentifier: "labelAssignmentReorderButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: rebuildVisibleItems
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "labelAssignmentOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { showsOverflowMenu.toggle() }
                )
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } results: {
                labelList
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "assign_labels", defaultValue: "Assign labels"),
                accessibilityIdentifier: "labelAssignmentScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .task(id: routeIdentity) {
            loadAssignmentState()
        }
        .onChange(of: searchText) { _, _ in
            rebuildVisibleItems()
        }
        .onChange(of: labelFingerprint) { _, _ in
            reconcileLabelsAfterExternalMutation()
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 300,
            estimatedMenuHeight: 88,
            accessibilityIdentifier: "labelAssignmentOverflowMenu"
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

    /// Route identity reloads only when the parent selects a different bookmark set/workspace.
    private var routeIdentity: String {
        bookmarkIDs.map(\.uuidString).sorted().joined(separator: ",")
            + "#" + (workspace?.id.uuidString ?? "none")
    }

    /// Android's retained mixed category-and-label list.
    private var labelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    switch item {
                    case .category(let category):
                        AndroidManageLabelCategoryRow(category: category, surfacePalette: surfacePalette)
                    case .label(let id):
                        if let label = allLabels.first(where: { $0.id == id }) {
                            assignmentRow(label)
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
                    .accessibilityIdentifier("labelAssignmentProgress")
            }
        }
    }

    /// Binds one persisted label into the shared Manage Labels row using draft state only.
    private func assignmentRow(_ label: BibleCore.Label) -> some View {
        AndroidManageLabelRow(
            label: label,
            isSelected: selectedLabelIDs.contains(label.id),
            isFavourite: favouriteValue(for: label),
            isPrimary: primaryLabelID == label.id,
            isAutoAssigned: autoAssignLabelIDs.contains(label.id),
            hasWorkspaceOverride: workspaceOverrideModes[label.id] != nil,
            showsAssignment: true,
            showsFavourite: workspace != nil && label.id != Label.unlabeledId,
            showsPrimary: true,
            showsAutoAssign: workspace != nil && label.id != Label.unlabeledId,
            surfacePalette: surfacePalette,
            onEdit: { editingLabelID = label.id },
            onToggleAssignment: { toggleAssignment(label.id) },
            onToggleFavourite: { favouriteValues[label.id] = !favouriteValue(for: label) },
            onSelectPrimary: { primaryLabelID = label.id },
            onToggleAutoAssign: { toggleAutoAssignment(label.id) }
        )
    }

    /// Global app-owned popup using the same archive commands as Android Manage Labels.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "labelAssignmentOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "export_something", defaultValue: "Export %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "labelAssignmentExportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginExport()
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "labelAssignmentImportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginImport()
                }
            }
        }
    }

    /// Full app-owned editors and dialogs, ordered so only one modal surface can receive input.
    @ViewBuilder
    private var presentationLayer: some View {
        if let newLabelDraft {
            AndroidLabelEditorView(
                draft: newLabelDraft,
                workspace: workspace,
                surfacePalette: surfacePalette,
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
            AndroidManageLabelsHelpDialog(mode: .assign) {
                showsHelp = false
            }
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
                accessibilityIdentifier: "labelAssignmentFeedbackDialog"
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
                accessibilityIdentifier: "labelAssignmentArchiveFeedbackDialog"
            )
        }
    }

    /// Loads union selection and workspace state without mutating the live route context.
    private func loadAssignmentState() {
        guard !hasLoaded else { return }
        do {
            let service = WorkspaceLabelConfigurationService(modelContext: modelContext)
            let snapshot = try service.bookmarkLabelAssignmentSnapshot(
                bookmarkIDs: bookmarkIDs,
                workspaceID: workspace?.id
            )
            selectedLabelIDs = snapshot.selectedLabelIDs
            primaryLabelID = snapshot.primaryLabelID
            autoAssignLabelIDs = snapshot.autoAssignLabelIDs
            autoAssignPrimaryLabelID = snapshot.autoAssignPrimaryLabelID
            recentLabelIDs = snapshot.recentLabelIDs
            refreshWorkspaceOverrides()
            hasLoaded = true
            rebuildVisibleItems()
        } catch {
            feedback = Feedback(
                title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                message: error.localizedDescription
            )
            hasLoaded = true
        }
    }

    /// Reconciles query changes from the full editor or archive import without resetting drafts.
    private func reconcileLabelsAfterExternalMutation() {
        guard hasLoaded else { return }
        let liveIDs = Set(allLabels.map(\.id))
        selectedLabelIDs.formIntersection(liveIDs)
        autoAssignLabelIDs.formIntersection(liveIDs)
        favouriteValues = favouriteValues.filter { liveIDs.contains($0.key) }
        if primaryLabelID.map({ !selectedLabelIDs.contains($0) }) == true {
            primaryLabelID = orderedIDs(in: selectedLabelIDs).first
        }
        if autoAssignPrimaryLabelID.map({ !autoAssignLabelIDs.contains($0) }) == true {
            autoAssignPrimaryLabelID = orderedIDs(in: autoAssignLabelIDs).first
        }
        refreshWorkspaceOverrides()
        rebuildVisibleItems()
    }

    /// Reads workspace override markers from their canonical fidelity owner.
    private func refreshWorkspaceOverrides() {
        guard let workspace else {
            workspaceOverrideModes = [:]
            return
        }
        let service = WorkspaceLabelConfigurationService(modelContext: modelContext)
        workspaceOverrideModes = Dictionary(uniqueKeysWithValues: assignableLabels.compactMap { label in
            service.configuration(for: label.id, in: workspace).overrideMode.map { (label.id, $0) }
        })
    }

    /// Rebuilds Android's category/header ordering after load, search, or explicit Reorder only.
    private func rebuildVisibleItems() {
        guard hasLoaded else { return }
        visibleItems = AndroidManageLabelsListProjection.items(
            labels: assignableLabels,
            activeLabelIDs: selectedLabelIDs,
            recentLabelIDs: recentLabelIDs,
            alwaysVisibleLabelIDs: selectedLabelIDs,
            searchText: searchText,
            searchesAnywhereInName: searchesAnywhereInName
        )
    }

    /// Toggles assignment without reordering until Android's refresh action is used.
    private func toggleAssignment(_ labelID: UUID) {
        if selectedLabelIDs.remove(labelID) != nil {
            if primaryLabelID == labelID || primaryLabelID == nil {
                primaryLabelID = orderedIDs(in: selectedLabelIDs).first
            }
        } else {
            selectedLabelIDs.insert(labelID)
            if primaryLabelID == nil { primaryLabelID = labelID }
        }
    }

    /// Toggles workspace auto-assignment and maintains Android's primary invariant.
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

    /// Current favourite value from the unsaved session or persisted label fallback.
    private func favouriteValue(for label: BibleCore.Label) -> Bool {
        favouriteValues[label.id] ?? label.favourite
    }

    /// Creates complete editor values without dropping the parent session's favourite change.
    private func editorValues(for label: BibleCore.Label) -> LabelEditValues {
        var values = LabelEditValues(label: label)
        values.favourite = favouriteValue(for: label)
        return values
    }

    /// Creates complete editor workspace values from the parent assignment session.
    private func editorWorkspaceConfiguration(for label: BibleCore.Label) -> WorkspaceLabelConfiguration {
        WorkspaceLabelConfiguration(
            isAutoAssigned: autoAssignLabelIDs.contains(label.id),
            isPrimaryAutoAssigned: autoAssignPrimaryLabelID == label.id,
            overrideMode: workspaceOverrideModes[label.id]
        )
    }

    /// Merges full-editor Save results back into the current Manage Labels session.
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
            selectedLabelIDs.insert(labelID)
            primaryLabelID = labelID
        }
    }

    /// Creates Android's unsaved full-editor draft with suggested search name and opaque color.
    private func beginNewLabel() {
        showsOverflowMenu = false
        let suggestedName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let red = UInt32.random(in: 0...254)
        let green = UInt32.random(in: 0...254)
        let blue = UInt32.random(in: 0...254)
        let color = Int(Int32(bitPattern: 0xFF000000 | red << 16 | green << 8 | blue))
        newLabelDraft = AndroidLabelEditorDraft(newLabelName: suggestedName, color: color)
    }

    /// Commits one complete generation, then closes only after persistence succeeds.
    private func commitAndClose() {
        guard hasLoaded, !isCommitting else { return }
        isCommitting = true
        do {
            try WorkspaceLabelConfigurationService(modelContext: modelContext)
                .commitBookmarkLabelAssignment(
                    bookmarkIDs: bookmarkIDs,
                    orderedSelectedLabelIDs: orderedIDs(in: selectedLabelIDs),
                    primaryLabelID: primaryLabelID,
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

    /// Stable Android-visible ordering for exact-set persistence and primary repair.
    private func orderedIDs(in ids: Set<UUID>) -> [UUID] {
        assignableLabels.map(\.id).filter(ids.contains)
    }

    /// Closes through the parent route owner or standalone SwiftUI destination.
    private func close() {
        if let onDismiss { onDismiss() } else { dismiss() }
    }

}
