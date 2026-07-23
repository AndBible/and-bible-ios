// AndroidHiddenLabelsActivityView.swift -- Manage Labels HIDELABELS activity

import BibleCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Presents Android `ManageLabels.Mode.HIDELABELS` as a full app-owned activity.

 The route composes the same shared action bar, Ab* search strip, category projection, label row,
 Help dialog, label editor, popup menu, and Study Pad archive workflow used by the other Manage
 Labels modes. Selection is staged until Back, while Reset writes `nil` to restore Android parent
 inheritance instead of persisting an empty override.

 Inputs: live label catalog, hidden-label binding, current owner scope, owner palette, and close hook

 Output: one searchable Active/Recent/Other checkbox activity matching Android Hide Labels mode

 Side effects: Back/Reset writes the hidden-label binding; label editing and archive commands use
 their canonical persistence services and platform file handoff boundaries

 Failure modes: archive/editor failures remain in their shared app-owned dialogs; label IDs removed
 externally are pruned before commit
 */
struct AndroidHiddenLabelsActivityView: View {
    private enum PopupAnchor {
        static let overflow = "hiddenLabelsOverflowAnchor"
    }

    let labels: [BibleCore.Label]
    @Binding var hiddenLabelIDs: [UUID]?
    let isWindow: Bool
    let surfacePalette: ReaderThemeSurfacePalette
    let onDismiss: () -> Void
    let onChange: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("labels_list_filter_searchInsideTextButtonActive")
    private var searchesAnywhereInName = false

    @State private var selectedLabelIDs: Set<UUID>
    @State private var visibleItems: [AndroidManageLabelListItem] = []
    @State private var searchText = ""
    @State private var hasLoaded = false

    @State private var showsOverflowMenu = false
    @State private var showsHelp = false
    @State private var showsResetConfirmation = false
    @State private var newLabelDraft: AndroidLabelEditorDraft?
    @State private var editingLabelID: UUID?
    @State private var archiveWorkflow = AndroidStudyPadArchiveWorkflow()

    /** Creates a staged Hide Labels activity without mutating the supplied binding. */
    init(
        labels: [BibleCore.Label],
        hiddenLabelIDs: Binding<[UUID]?>,
        isWindow: Bool,
        surfacePalette: ReaderThemeSurfacePalette,
        onDismiss: @escaping () -> Void,
        onChange: (() -> Void)?
    ) {
        self.labels = labels
        _hiddenLabelIDs = hiddenLabelIDs
        self.isWindow = isWindow
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
        self.onChange = onChange
        _selectedLabelIDs = State(initialValue: Set(hiddenLabelIDs.wrappedValue ?? []))
    }

    /// Android Hide Labels includes every assignable row, including synthetic Unlabelled.
    private var assignableLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadExportLabels(from: labels)
    }

    /// Stable fingerprint used to reconcile edits, imports, and external deletions.
    private var labelFingerprint: String {
        labels.map { "\($0.id.uuidString):\($0.name):\($0.color):\($0.customIcon ?? "")" }
            .joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidManageLabelsActivityScreen(
            title: String(
                localized: "bookmark_settings_hide_labels_title",
                defaultValue: "Hide specified labels"
            ),
            appBarAccessibilityIdentifier: "hiddenLabelsAppBar",
            surfacePalette: surfacePalette,
            onBack: commitAndClose,
            compactModeTitle: searchesAnywhereInName ? "*ab*" : "Ab*",
            localizedModeTitle: searchesAnywhereInName
                ? String(localized: "search_mode_name_contains", defaultValue: "Name (contains)")
                : String(localized: "search_mode_name_start", defaultValue: "Name (from start)"),
            isModeActive: searchesAnywhereInName,
            searchText: $searchText,
            accessibilityPrefix: "hiddenLabels",
            onSelectSearchMode: {
                searchesAnywhereInName.toggle()
                rebuildVisibleItems()
            }
        ) {
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ActivityAddCircle"),
                accessibilityLabel: String(localized: "new_item", defaultValue: "New"),
                accessibilityIdentifier: "hiddenLabelsAddButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: beginNewLabel
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("DrawerHelp"),
                accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                accessibilityIdentifier: "hiddenLabelsHelpButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsHelp = true }
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ManageLabelsReorder"),
                accessibilityLabel: String(localized: "reorder", defaultValue: "Re-order"),
                accessibilityIdentifier: "hiddenLabelsReorderButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: rebuildVisibleItems
            )
            AndroidActivityTopAppBarActionButton(
                icon: .asset("ToolbarOverflow"),
                accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                accessibilityIdentifier: "hiddenLabelsOverflowButton",
                foregroundColor: surfacePalette.toolbarForegroundColor,
                action: { showsOverflowMenu.toggle() }
            )
            .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } results: {
                labelList
            }

            AndroidActivityAccessibilityMarker(
                label: String(
                    localized: "bookmark_settings_hide_labels_title",
                    defaultValue: "Hide specified labels"
                ),
                accessibilityIdentifier: "textDisplayHiddenBookmarkLabelsScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .task { load() }
        .onChange(of: searchText) { _, _ in rebuildVisibleItems() }
        .onChange(of: labelFingerprint) { _, _ in reconcileLiveLabels() }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 300,
            estimatedMenuHeight: 132,
            accessibilityIdentifier: "hiddenLabelsOverflowMenu"
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

    /// Android's retained category-and-label projection.
    private var labelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleItems) { item in
                    switch item {
                    case .category(let category):
                        AndroidManageLabelCategoryRow(category: category, surfacePalette: surfacePalette)
                    case .label(let id):
                        if let label = labels.first(where: { $0.id == id }) {
                            hiddenLabelRow(label)
                        }
                    }
                    Divider().overlay(surfacePalette.inactiveBorderColor)
                }
            }
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
                    .tint(surfacePalette.foregroundColor)
                    .accessibilityIdentifier("hiddenLabelsProgress")
            }
        }
    }

    /// Reuses the canonical Manage Labels row in checkbox-only Hide Labels mode.
    private func hiddenLabelRow(_ label: BibleCore.Label) -> some View {
        AndroidManageLabelRow(
            label: label,
            isSelected: selectedLabelIDs.contains(label.id),
            isFavourite: label.favourite,
            isPrimary: false,
            isAutoAssigned: false,
            hasWorkspaceOverride: false,
            showsAssignment: true,
            showsFavourite: false,
            showsPrimary: false,
            showsAutoAssign: false,
            surfacePalette: surfacePalette,
            onEdit: { editingLabelID = label.id },
            onToggleAssignment: { toggle(label.id) },
            onToggleFavourite: {},
            onSelectPrimary: {},
            onToggleAutoAssign: {}
        )
    }

    /// Android overflow rows visible from Hide Labels mode.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "hiddenLabelsOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                AndroidPopupMenuRow(
                    title: String(localized: "reset_generic", defaultValue: "Reset"),
                    accessibilityIdentifier: "hiddenLabelsResetAction"
                ) {
                    showsOverflowMenu = false
                    showsResetConfirmation = true
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "export_something", defaultValue: "Export %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "hiddenLabelsExportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginExport()
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "hiddenLabelsImportAction"
                ) {
                    showsOverflowMenu = false
                    archiveWorkflow.beginImport()
                }
            }
        }
    }

    /// App-owned editors and dialogs; only the first active surface can receive input.
    @ViewBuilder
    private var presentationLayer: some View {
        if let newLabelDraft {
            AndroidLabelEditorView(
                draft: newLabelDraft,
                surfacePalette: surfacePalette,
                onSaved: handleEditorSave,
                onCancel: { self.newLabelDraft = nil }
            )
        } else if let editingLabelID,
                  let label = labels.first(where: { $0.id == editingLabelID }) {
            AndroidLabelEditorView(
                label: label,
                surfacePalette: surfacePalette,
                onSaved: handleEditorSave,
                onClose: { self.editingLabelID = nil }
            )
        } else if showsHelp {
            AndroidManageLabelsHelpDialog(mode: .hideLabels(isWindow: isWindow)) {
                showsHelp = false
            }
        } else if showsResetConfirmation {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    localized: "reset_hide_labels",
                    defaultValue: "Reset hidden label settings?"
                ),
                actions: [
                    .init(
                        id: "reset",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .destructive
                    ) { resetAndClose() },
                    .init(
                        id: "cancel",
                        title: String(localized: "cancel", defaultValue: "Cancel"),
                        style: .normal
                    ) { showsResetConfirmation = false },
                ],
                accessibilityIdentifier: "hiddenLabelsResetDialog"
            )
        } else if archiveWorkflow.showsExportSelection {
            StudyPadExportSelectionDialog(
                labels: assignableLabels,
                selectedLabelIDs: Binding(
                    get: { archiveWorkflow.exportLabelIDs },
                    set: { archiveWorkflow.exportLabelIDs = $0 }
                ),
                isExporting: archiveWorkflow.isExporting,
                onCancel: archiveWorkflow.dismissExportSelection,
                onExport: {
                    archiveWorkflow.exportSelectedStudyPads(
                        labels: assignableLabels,
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
                        reconcileLiveLabels()
                    }
                }
            )
        } else if let feedback = archiveWorkflow.feedback {
            AndroidDecisionDialog(
                title: feedback.title,
                message: feedback.message,
                actions: [
                    .init(
                        id: "ok",
                        title: String(localized: "okay", defaultValue: "OK"),
                        style: .normal
                    ) { archiveWorkflow.feedback = nil },
                ],
                accessibilityIdentifier: "hiddenLabelsArchiveFeedbackDialog"
            )
        }
    }

    /// Seeds the retained Android list projection once after the activity appears.
    private func load() {
        guard !hasLoaded else { return }
        reconcileLiveLabels()
        hasLoaded = true
        rebuildVisibleItems()
    }

    /// Removes stale identities after label edit, deletion, import, or external synchronization.
    private func reconcileLiveLabels() {
        selectedLabelIDs.formIntersection(Set(labels.map(\.id)))
        if hasLoaded { rebuildVisibleItems() }
    }

    /// Rebuilds categories after load, search, or explicit Android Reorder.
    private func rebuildVisibleItems() {
        guard hasLoaded else { return }
        visibleItems = AndroidManageLabelsListProjection.items(
            labels: assignableLabels,
            activeLabelIDs: selectedLabelIDs,
            recentLabelIDs: [],
            alwaysVisibleLabelIDs: selectedLabelIDs,
            searchText: searchText,
            searchesAnywhereInName: searchesAnywhereInName
        )
    }

    /// Toggles one staged hidden-label identity without reordering the current list.
    private func toggle(_ labelID: UUID) {
        if selectedLabelIDs.remove(labelID) == nil {
            selectedLabelIDs.insert(labelID)
        }
    }

    /// Creates Android's unsaved new-label draft from the current search text and opaque color.
    private func beginNewLabel() {
        let suggestedName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let red = UInt32.random(in: 0...254)
        let green = UInt32.random(in: 0...254)
        let blue = UInt32.random(in: 0...254)
        let color = Int(Int32(bitPattern: 0xFF000000 | red << 16 | green << 8 | blue))
        newLabelDraft = AndroidLabelEditorDraft(newLabelName: suggestedName, color: color)
    }

    /// Closes the shared label editor and lets the live label query drive projection refresh.
    private func handleEditorSave(
        labelID: UUID,
        values: LabelEditValues,
        configuration: WorkspaceLabelConfiguration
    ) {
        _ = labelID
        _ = values
        _ = configuration
        newLabelDraft = nil
        editingLabelID = nil
    }

    /// Writes `nil` to restore inherited hidden-label state, then returns to Text Options.
    private func resetAndClose() {
        hiddenLabelIDs = nil
        onChange?()
        showsResetConfirmation = false
        onDismiss()
    }

    /// Commits the exact staged identities that still exist and returns to Text Options.
    private func commitAndClose() {
        let liveIDs = Set(labels.map(\.id))
        hiddenLabelIDs = assignableLabels.map(\.id).filter {
            liveIDs.contains($0) && selectedLabelIDs.contains($0)
        }
        onChange?()
        onDismiss()
    }
}
