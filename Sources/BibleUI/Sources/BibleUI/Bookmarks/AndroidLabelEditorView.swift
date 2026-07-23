// AndroidLabelEditorView.swift -- Canonical app-owned Android label editor

import BibleCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Editable value copy of Android label fields.

 The draft wraps BibleCore's complete `LabelEditValues` contract and adds only presentation facts
 that Android derives from the original label identity. No SwiftData object is mutated until Save.
 */
struct AndroidLabelEditorDraft: Equatable {
    /// Complete persistence-owned editable scalar state.
    var values: LabelEditValues

    /// Whether the original label is one of Android's fixed reserved labels.
    let isSystemLabel: Bool

    /// Whether the original label is Android's Speak label, whose custom icon control is hidden.
    let isSpeakLabel: Bool

    var name: String {
        get { values.name }
        set { values.name = newValue }
    }

    var color: Int {
        get { values.color }
        set { values.color = newValue }
    }

    var markerStyle: Bool {
        get { values.markerStyle }
        set { values.markerStyle = newValue }
    }

    var markerStyleWholeVerse: Bool {
        get { values.markerStyleWholeVerse }
        set { values.markerStyleWholeVerse = newValue }
    }

    var underlineStyle: Bool {
        get { values.underlineStyle }
        set { values.underlineStyle = newValue }
    }

    var underlineStyleWholeVerse: Bool {
        get { values.underlineStyleWholeVerse }
        set { values.underlineStyleWholeVerse = newValue }
    }

    var hideStyle: Bool {
        get { values.hideStyle }
        set { values.hideStyle = newValue }
    }

    var hideStyleWholeVerse: Bool {
        get { values.hideStyleWholeVerse }
        set { values.hideStyleWholeVerse = newValue }
    }

    var favourite: Bool {
        get { values.favourite }
        set { values.favourite = newValue }
    }

    var customIcon: String? {
        get { values.customIcon }
        set { values.customIcon = newValue }
    }

    /** Creates a draft containing every persisted Android-editable field. */
    init(label: BibleCore.Label) {
        self.init(label: label, values: LabelEditValues(label: label))
    }

    /**
     Creates an existing-label draft from caller-owned unsaved Manage Labels values.

     - Parameters:
       - label: Persisted identity used to retain system-label restrictions.
       - values: Complete draft values already edited by the parent Manage Labels session.
     - Side effects: none.
     - Failure modes: none; validation remains the editor's Save responsibility.
     */
    init(label: BibleCore.Label, values: LabelEditValues) {
        self.values = values
        isSystemLabel = label.isSystemLabel
        isSpeakLabel = label.name == BibleCore.Label.speakLabelName
    }

    /** Creates Android's unsaved new-label draft using the caller's suggested name and color. */
    init(newLabelName: String, color: Int) {
        values = LabelEditValues(name: newLabelName, color: color)
        isSystemLabel = false
        isSpeakLabel = false
    }
}

/**
 Canonical app-owned equivalent of Android `LabelEditActivity`.

 The editor uses the shared activity bar, anchored popup surface, checkbox row, dialog window,
 color picker, icon picker, archive service, and BibleCore label/workspace transaction. Its layout
 and enablement rules follow Android's `bookmark_label_edit.xml` and `updateUI()` rather than an iOS
 `Form` approximation.

 Inputs: existing or unsaved label values, optional active workspace, owner palette, and close action

 Outputs: one explicitly saved label/workspace generation, one explicit deletion choice, or no change

 Side effects: may commit label/workspace journals, delete a label and selected orphan bookmarks,
 build one Study Pad export archive, or hand a completed archive to the platform Files destination

 Failure modes: validation, persistence, journal, and archive failures remain visible in the route's
 shared app-owned decision dialog; cancel/discard never mutates live SwiftData objects
 */
struct AndroidLabelEditorView: View {
    /// Named anchors shared with the reusable app-owned popup presenter.
    private enum PopupAnchor {
        static let overflow = "androidLabelEditorOverflowAnchor"
        static let overrideMode = "androidLabelEditorOverrideAnchor"
    }

    /// Existing label model used only for identity/deletion preview; nil for a new draft.
    private let existingLabel: BibleCore.Label?

    /// Stable label identity allocated before new-label workspace configuration is saved.
    private let labelID: UUID

    /// Active workspace whose Android label settings are edited with the label.
    private let workspace: Workspace?

    /// Optional reader/workspace palette supplied by the owning route.
    private let suppliedSurfacePalette: ReaderThemeSurfacePalette?

    /// Owner callback used instead of native navigation dismissal when embedded in reader routes.
    private let onClose: (() -> Void)?

    /// Optional observer receiving the exact label/workspace generation after a successful Save.
    private let onSaved: ((UUID, LabelEditValues, WorkspaceLabelConfiguration) -> Void)?

    /// Parent-session workspace draft supplied by Manage Labels modes, if any.
    private let suppliedWorkspaceConfiguration: WorkspaceLabelConfiguration?

    /// Original immutable draft used for discard decisions.
    private let originalDraft: AndroidLabelEditorDraft

    /// Current unsaved label values.
    @State private var draft: AndroidLabelEditorDraft

    /// Original workspace values loaded from their canonical owners.
    @State private var originalWorkspaceConfiguration = WorkspaceLabelConfiguration()

    /// Current unsaved workspace label values.
    @State private var workspaceConfiguration = WorkspaceLabelConfiguration()

    /// Whether the workspace projection has completed before Save can proceed.
    @State private var hasLoadedWorkspaceConfiguration = false

    /// App-owned popup visibility.
    @State private var showsOverflowMenu = false
    @State private var showsOverrideMenu = false

    /// App-owned dialog visibility.
    @State private var showsColorPicker = false
    @State private var showsIconPicker = false
    @State private var showsDiscardConfirmation = false
    @State private var showsDeleteConfirmation = false

    /// Canonical deletion preview used for both copy and eventual service call.
    @State private var deletionImpact: BookmarkLabelDeletionImpact?

    /// Persistence or validation failure retained for app-owned presentation.
    @State private var errorMessage: String?

    /// Single-label Android Study Pad export state.
    @State private var isExporting = false
    @State private var preparedExport: AndroidStudyPadArchiveExport?
    @State private var exportDocument = BackupExportDocument()
    @State private var exportFileName = AndroidStudyPadArchiveService.multipleStudyPadsFileName
    @State private var showsFileExporter = false

    /// SwiftData context used for service construction, read projection, and deletion preview.
    @Environment(\.modelContext) private var modelContext

    /// Environment dismissal used by standalone Label Manager navigation.
    @Environment(\.dismiss) private var dismiss

    /// Active application scheme used by shared AppCompat colors.
    @Environment(\.colorScheme) private var colorScheme

    /**
     Creates a draft editor for one existing label and optional active workspace.

     Parent Manage Labels sessions may supply unsaved label/workspace values so opening the shared
     editor never discards favourite or auto-assignment changes that have not reached the activity
     Back/commit boundary yet.
     */
    init(
        label: BibleCore.Label,
        initialValues: LabelEditValues? = nil,
        workspace: Workspace? = nil,
        initialWorkspaceConfiguration: WorkspaceLabelConfiguration? = nil,
        surfacePalette: ReaderThemeSurfacePalette? = nil,
        onSaved: ((UUID, LabelEditValues, WorkspaceLabelConfiguration) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        let initial = AndroidLabelEditorDraft(
            label: label,
            values: initialValues ?? LabelEditValues(label: label)
        )
        existingLabel = label
        labelID = label.id
        self.workspace = workspace
        suppliedWorkspaceConfiguration = initialWorkspaceConfiguration
        suppliedSurfacePalette = surfacePalette
        self.onSaved = onSaved
        self.onClose = onClose
        originalDraft = initial
        _draft = State(initialValue: initial)
    }

    /**
     Creates an unsaved new-label editor without inserting a SwiftData row.

     - Parameters:
       - draft: Suggested-name/random-color draft matching Android `newLabel()`.
       - workspace: Active workspace whose auto-assignment/override fields should be shown.
       - surfacePalette: Owning reader/workspace palette.
       - initialWorkspaceConfiguration: Optional parent-session workspace draft.
       - onSaved: Observer called with the committed identity and complete values.
       - onCancel: Closes the owner route after save or cancellation.
     - Side effects: none until explicit Save, export, or cancellation.
     - Failure modes: Save failures remain in the editor without inserting a partial label.
     */
    init(
        draft: AndroidLabelEditorDraft,
        workspace: Workspace? = nil,
        surfacePalette: ReaderThemeSurfacePalette,
        initialWorkspaceConfiguration: WorkspaceLabelConfiguration? = nil,
        onSaved: ((UUID, LabelEditValues, WorkspaceLabelConfiguration) -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        existingLabel = nil
        labelID = UUID()
        self.workspace = workspace
        suppliedWorkspaceConfiguration = initialWorkspaceConfiguration
        suppliedSurfacePalette = surfacePalette
        self.onSaved = onSaved
        onClose = onCancel
        originalDraft = draft
        _draft = State(initialValue: draft)
    }

    /// Palette inherited from the reader or resolved from application day/night defaults.
    private var surfacePalette: ReaderThemeSurfacePalette {
        suppliedSurfacePalette
            ?? ReaderThemeSurfacePalette(settings: .appDefaults, nightMode: colorScheme == .dark)
    }

    /// Central AppCompat accent shared with dialogs and management fields.
    private var accentColor: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    /// Whether Android shows the workspace category for this editor.
    private var showsWorkspaceSection: Bool {
        workspace != nil && !draft.isSystemLabel
    }

    /// Complete dirty state across both Android persistence owners.
    private var hasUnsavedChanges: Bool {
        draft != originalDraft || workspaceConfiguration != originalWorkspaceConfiguration
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "edit_label", defaultValue: "Edit label"),
                accessibilityIdentifier: "androidLabelEditorAppBar",
                palette: surfacePalette,
                onBack: requestClose
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivitySave"),
                    accessibilityLabel: String(localized: "okay", defaultValue: "OK"),
                    accessibilityIdentifier: "labelEditDoneButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: commit
                )
                if existingLabel != nil, !draft.isSystemLabel {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("ActivityDelete"),
                        accessibilityLabel: String(localized: "delete"),
                        accessibilityIdentifier: "labelEditDeleteButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor,
                        action: prepareDeletion
                    )
                }
                if existingLabel != nil {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("ToolbarOverflow"),
                        accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                        accessibilityIdentifier: "labelEditOverflowButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor,
                        action: {
                            showsOverrideMenu = false
                            showsOverflowMenu.toggle()
                        }
                    )
                    .androidPopupMenuAnchor(id: PopupAnchor.overflow)
                }
            } content: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identitySection
                        styleSection
                        if showsWorkspaceSection {
                            workspaceSection
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "edit_label", defaultValue: "Edit label"),
                accessibilityIdentifier: "labelEditScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .task(id: "\(labelID.uuidString)#\(workspace?.id.uuidString ?? "none")") {
            loadWorkspaceConfiguration()
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 220,
            estimatedMenuHeight: 48,
            accessibilityIdentifier: "labelEditOverflowMenu"
        ) {
            overflowMenu
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overrideMode,
            isPresented: $showsOverrideMenu,
            menuWidth: 300,
            estimatedMenuHeight: 240,
            accessibilityIdentifier: "labelEditOverrideMenu"
        ) {
            overrideMenu
        }
        .overlay { dialogOverlay }
        .fileExporter(
            isPresented: $showsFileExporter,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: exportFileName,
            onCompletion: handleFileExportCompletion
        )
    }

    /// Android title-tag color control, label name, and favourite row.
    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    closePopups()
                    showsColorPicker = true
                } label: {
                    AndBibleIconView(name: "LabelTag", size: 30)
                        .foregroundStyle(Color(argbInt: draft.color))
                        .frame(width: 38, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "select_color", defaultValue: "Select color"))
                .accessibilityIdentifier("labelEditColorButton")

                TextField(
                    String(localized: "label_name_prompt", defaultValue: "Name"),
                    text: $draft.name
                )
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .disabled(draft.isSystemLabel)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(draft.isSystemLabel ? surfacePalette.inactiveBorderColor : accentColor)
                        .frame(height: 1)
                }
                .opacity(draft.isSystemLabel ? 0.55 : 1)
                .accessibilityIdentifier("labelEditNameField")
            }

            if !draft.isSystemLabel {
                AndroidCheckboxRow(
                    title: String(localized: "favourite_label", defaultValue: "Favourite label"),
                    isOn: $draft.favourite,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditFavourite"
                )
            }
        }
    }

    /// Android Bookmark Style category with its shared custom-icon selector and exact enable rules.
    private var styleSection: some View {
        editorSection(String(localized: "bookmark_style", defaultValue: "Bookmark style")) {
            VStack(alignment: .leading, spacing: 0) {
                if !draft.isSpeakLabel {
                    Button {
                        closePopups()
                        showsIconPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let customIcon = draft.customIcon {
                                    AndroidLabelIconView(name: customIcon, size: 24)
                                } else {
                                    AndBibleIconView(
                                        name: AndroidLabelIconAsset.defaultBookmarkAssetName,
                                        size: 24
                                    )
                                }
                            }
                            .foregroundStyle(draft.customIcon == nil
                                ? AndroidResourcePalette.grey500
                                : Color(argbInt: draft.color))
                            .frame(width: 30, height: 30)
                            Text(String(localized: "select_custom_icon", defaultValue: "Select custom marker icon"))
                                .font(.system(size: 17))
                                .foregroundStyle(surfacePalette.foregroundColor)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("labelEditCustomIconButton")
                }

                AndroidCheckboxRow(
                    title: String(
                        localized: "bookmark_underline_style_arbitrary",
                        defaultValue: "Underline style for selection bookmarks"
                    ),
                    isOn: $draft.underlineStyle,
                    isEnabled: !draft.hideStyle && !draft.markerStyle,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditUnderline"
                )
                AndroidCheckboxRow(
                    title: String(
                        localized: "bookmark_underline_style_whole_verse",
                        defaultValue: "Underline style for whole verse bookmarks"
                    ),
                    isOn: $draft.underlineStyleWholeVerse,
                    isEnabled: !draft.hideStyleWholeVerse && !draft.markerStyleWholeVerse,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditUnderlineWholeVerse"
                )
                AndroidCheckboxRow(
                    title: String(localized: "marker_style", defaultValue: "Marker style"),
                    isOn: $draft.markerStyle,
                    isEnabled: !draft.hideStyle,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditMarker"
                )
                AndroidCheckboxRow(
                    title: String(localized: "marker_style_whole_verse", defaultValue: "Marker whole verse"),
                    isOn: $draft.markerStyleWholeVerse,
                    isEnabled: !draft.hideStyleWholeVerse,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditMarkerWholeVerse"
                )
                AndroidCheckboxRow(
                    title: String(localized: "hide_style", defaultValue: "Hide style"),
                    isOn: $draft.hideStyle,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditHidden"
                )
                AndroidCheckboxRow(
                    title: String(localized: "hide_style_whole_verse", defaultValue: "Hide whole verse"),
                    isOn: $draft.hideStyleWholeVerse,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditHiddenWholeVerse"
                )
            }
        }
    }

    /// Android This Workspace category backed by the actual workspace and fidelity stores.
    private var workspaceSection: some View {
        editorSection(String(localized: "this_workspace", defaultValue: "This workspace")) {
            VStack(alignment: .leading, spacing: 0) {
                AndroidCheckboxRow(
                    title: String(
                        localized: "auto_assign_labels1",
                        defaultValue: "Auto-assign label to new bookmarks"
                    ),
                    isOn: $workspaceConfiguration.isAutoAssigned,
                    isEnabled: hasLoadedWorkspaceConfiguration,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditAutoAssign"
                )
                .onChange(of: workspaceConfiguration.isAutoAssigned) { _, isAutoAssigned in
                    if !isAutoAssigned {
                        workspaceConfiguration.isPrimaryAutoAssigned = false
                    }
                }

                AndroidCheckboxRow(
                    title: String(
                        localized: "auto_assign_labels_primary",
                        defaultValue: "Auto-assign as primary"
                    ),
                    isOn: $workspaceConfiguration.isPrimaryAutoAssigned,
                    isEnabled: hasLoadedWorkspaceConfiguration && workspaceConfiguration.isAutoAssigned,
                    foregroundColor: surfacePalette.foregroundColor,
                    accentColor: accentColor,
                    accessibilityIdentifier: "labelEditPrimaryAutoAssign"
                )
                .padding(.leading, 15)

                AndroidSelectionField(
                    title: String(localized: "override_style", defaultValue: "Override style"),
                    value: overrideTitle(for: workspaceConfiguration.overrideMode),
                    isEnabled: hasLoadedWorkspaceConfiguration,
                    palette: surfacePalette,
                    accessibilityIdentifier: "labelEditOverrideField"
                ) {
                    showsOverflowMenu = false
                    showsOverrideMenu.toggle()
                }
                .padding(.top, 8)
                .androidPopupMenuAnchor(id: PopupAnchor.overrideMode)
            }
        }
    }

    /// Shared section layout matching Android category-title spacing.
    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shared owner-paletted overflow menu for Android's existing-label Export command.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "labelEditOverflowSurface",
            backgroundColor: surfacePalette.controlFillColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: accentColor
        ) {
            AndroidPopupMenuRow(
                title: String(localized: "export", defaultValue: "Export"),
                icon: .asset("ActivityShare"),
                accessibilityIdentifier: "labelEditExportAction"
            ) {
                showsOverflowMenu = false
                exportStudyPad()
            }
        }
    }

    /// Shared owner-paletted dropdown for Android's five workspace display-mode choices.
    private var overrideMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "labelEditOverrideSurface",
            backgroundColor: surfacePalette.controlFillColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: accentColor
        ) {
            VStack(spacing: 0) {
                ForEach(Array(overrideOptions.enumerated()), id: \.offset) { _, option in
                    AndroidPopupMenuRow(
                        title: option.title,
                        accessory: .checkbox(isOn: workspaceConfiguration.overrideMode == option.mode),
                        accessibilityIdentifier: "labelEditOverrideOption::\(option.mode.map(String.init) ?? "none")"
                    ) {
                        workspaceConfiguration.overrideMode = option.mode
                        showsOverrideMenu = false
                    }
                }
            }
        }
    }

    /// Ordered Android spinner options where nil is position zero and modes 0...3 follow.
    private var overrideOptions: [(mode: Int?, title: String)] {
        [
            (nil, String(localized: "no_override_suffix", defaultValue: "No override")),
            (0, String(localized: "display_mode_highlight", defaultValue: "Highlight")),
            (1, String(localized: "display_mode_underline", defaultValue: "Underline")),
            (2, String(localized: "display_mode_marker", defaultValue: "Marker only")),
            (3, String(localized: "display_mode_hidden", defaultValue: "Hidden")),
        ]
    }

    /// Resolves one optional Android override ordinal into its localized dropdown title.
    private func overrideTitle(for mode: Int?) -> String {
        overrideOptions.first(where: { $0.mode == mode })?.title
            ?? String(localized: "no_override_suffix", defaultValue: "No override")
    }

    /// App-owned color/icon/decision dialogs in exclusive priority order.
    @ViewBuilder
    private var dialogOverlay: some View {
        if showsColorPicker {
            AndroidColorPickerDialog(
                initialColor: draft.color,
                onCancel: { showsColorPicker = false },
                onSelect: { color in
                    draft.color = color
                    showsColorPicker = false
                }
            )
        } else if showsIconPicker {
            AndroidLabelIconPickerDialog(
                selectedIcon: draft.customIcon,
                onCancel: { showsIconPicker = false },
                onSelect: { icon in
                    draft.customIcon = icon
                    showsIconPicker = false
                }
            )
        } else if showsDiscardConfirmation {
            AndroidDecisionDialog(
                title: String(localized: "discard_changes_confirmation", defaultValue: "Discard changes?"),
                message: nil,
                actions: [
                    .init(id: "no", title: String(localized: "no"), style: .normal) {
                        showsDiscardConfirmation = false
                    },
                    .init(id: "yes", title: String(localized: "yes"), style: .destructive) {
                        showsDiscardConfirmation = false
                        close()
                    },
                ],
                accessibilityIdentifier: "labelEditDiscardDialog"
            )
        } else if showsDeleteConfirmation {
            deleteConfirmationDialog
        } else if let errorMessage {
            AndroidDecisionDialog(
                title: String(localized: "error_occurred", defaultValue: "Error"),
                message: errorMessage,
                actions: [
                    .init(id: "ok", title: String(localized: "okay", defaultValue: "OK"), style: .normal) {
                        self.errorMessage = nil
                    },
                ],
                accessibilityIdentifier: "labelEditErrorDialog"
            )
        }
    }

    /// Android's two- or three-choice label deletion confirmation based on canonical preview count.
    private var deleteConfirmationDialog: some View {
        AndroidDecisionDialog(
            title: String(localized: "delete"),
            message: deletionMessage,
            actions: deletionActions,
            accessibilityIdentifier: "labelEditDeleteDialog"
        )
    }

    /// Exact Android deletion copy including orphan bookmark count when applicable.
    private var deletionMessage: String {
        let base = String(
            format: String(localized: "delete_label_confirmation", defaultValue: "Delete label %@?"),
            draft.name
        )
        guard let deletionImpact, deletionImpact.orphanedBookmarkCount > 0 else { return base }
        let orphanCopy = String(
            format: String(
                localized: "confirm_delete_orphaned_bookmarks",
                defaultValue: "The selected label is attached to %d bookmarks that have no other labels. Do you want to delete these bookmarks along with the labels?"
            ),
            deletionImpact.orphanedBookmarkCount
        )
        return "\(base)\n\n\(orphanCopy)"
    }

    /// Android deletion action set selected from whether orphan bookmarks exist.
    private var deletionActions: [AndroidDecisionDialog.Action] {
        if let deletionImpact, deletionImpact.orphanedBookmarkCount > 0 {
            return [
                .init(
                    id: "deleteLabelAndBookmarks",
                    title: String(
                        localized: "delete_label_and_bookmarks",
                        defaultValue: "Delete label and bookmarks"
                    ),
                    style: .destructive,
                    perform: { deleteExistingLabel(deleteOrphanedBookmarks: true) }
                ),
                .init(
                    id: "deleteLabelOnly",
                    title: String(localized: "delete_label_only", defaultValue: "Delete label only"),
                    style: .destructive,
                    perform: { deleteExistingLabel(deleteOrphanedBookmarks: false) }
                ),
                .init(id: "cancel", title: String(localized: "cancel"), style: .normal) {
                    showsDeleteConfirmation = false
                },
            ]
        }
        return [
            .init(id: "no", title: String(localized: "no"), style: .normal) {
                showsDeleteConfirmation = false
            },
            .init(id: "yes", title: String(localized: "yes"), style: .destructive) {
                deleteExistingLabel(deleteOrphanedBookmarks: false)
            },
        ]
    }

    /// Loads the complete persisted workspace projection once, or Android's empty new-label default.
    private func loadWorkspaceConfiguration() {
        guard !hasLoadedWorkspaceConfiguration else { return }
        let configuration: WorkspaceLabelConfiguration
        if let suppliedWorkspaceConfiguration {
            configuration = suppliedWorkspaceConfiguration
        } else if existingLabel != nil {
            configuration = WorkspaceLabelConfigurationService(modelContext: modelContext)
                .configuration(for: labelID, in: workspace)
        } else {
            configuration = WorkspaceLabelConfiguration()
        }
        originalWorkspaceConfiguration = configuration
        workspaceConfiguration = configuration
        hasLoadedWorkspaceConfiguration = true
    }

    /// Validates and commits through the isolated BibleCore cross-category transaction.
    private func commit() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.isSystemLabel || !trimmedName.isEmpty else {
            errorMessage = String(localized: "label_name_required", defaultValue: "Label name is required.")
            return
        }
        guard !showsWorkspaceSection || hasLoadedWorkspaceConfiguration else {
            errorMessage = String(localized: "please_wait", defaultValue: "Please wait")
            return
        }
        draft.name = trimmedName
        closePopups()
        do {
            let service = WorkspaceLabelConfigurationService(modelContext: modelContext)
            if existingLabel != nil {
                try service.updateLabel(
                    id: labelID,
                    values: draft.values,
                    workspaceID: workspace?.id,
                    configuration: workspaceConfiguration
                )
            } else {
                try service.createLabel(
                    id: labelID,
                    values: draft.values,
                    workspaceID: workspace?.id,
                    configuration: workspaceConfiguration
                )
            }
            onSaved?(labelID, draft.values, workspaceConfiguration)
            close()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Requests cancellation while preserving Android's complete draft discard confirmation.
    private func requestClose() {
        closePopups()
        if hasUnsavedChanges {
            showsDiscardConfirmation = true
        } else {
            close()
        }
    }

    /// Loads the service-owned orphan preview before presenting Android's deletion choices.
    private func prepareDeletion() {
        guard let existingLabel, !draft.isSystemLabel else { return }
        closePopups()
        deletionImpact = LabelManagerMutation.deletionImpact(for: existingLabel, in: modelContext)
        guard deletionImpact != nil else {
            errorMessage = WorkspaceLabelConfigurationError.labelNotFound(existingLabel.id).localizedDescription
            return
        }
        showsDeleteConfirmation = true
    }

    /// Applies the exact deletion choice through the canonical bookmark service path.
    private func deleteExistingLabel(deleteOrphanedBookmarks: Bool) {
        guard let existingLabel, !draft.isSystemLabel else { return }
        do {
            try LabelManagerMutation.deleteLabel(
                existingLabel,
                deleteOrphanedBookmarks: deleteOrphanedBookmarks,
                in: modelContext
            )
            showsDeleteConfirmation = false
            close()
        } catch {
            showsDeleteConfirmation = false
            errorMessage = error.localizedDescription
        }
    }

    /// Builds Android's specialized single-label Study Pad archive for system Files handoff.
    private func exportStudyPad() {
        guard existingLabel != nil, !isExporting else { return }
        isExporting = true
        let modelContainer = modelContext.container
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try AndroidStudyPadArchiveService().exportArchiveFile(
                        labelIDs: [labelID],
                        modelContext: ModelContext(modelContainer)
                    )
                }.value
                preparedExport = export
                exportDocument = BackupExportDocument(fileURL: export.fileURL)
                exportFileName = export.fileName
                showsFileExporter = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Removes the temporary archive and reports only system destination failures.
    private func handleFileExportCompletion(_ result: Result<URL, Error>) {
        if let preparedExport {
            AndroidStudyPadArchiveService().cleanup(preparedExport)
            self.preparedExport = nil
        }
        exportDocument = BackupExportDocument()
        if case .failure(let error) = result {
            errorMessage = error.localizedDescription
        }
    }

    /// Closes every app-owned popup before navigation or modal presentation changes.
    private func closePopups() {
        showsOverflowMenu = false
        showsOverrideMenu = false
    }

    /// Closes through the owner callback or current standalone navigation destination.
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
