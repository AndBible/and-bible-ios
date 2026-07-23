// StudyPadSelectorView.swift -- Android-parity app-owned Study Pad selector

import BibleCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/**
 Renders Android `ManageLabels.Mode.STUDYPAD` as an app-owned reader route.

 This view composes shared activity chrome, popup rows/surfaces, Help content, label editor,
 checkboxes, database/ZIP services, and the owner-provided reader palette. It owns only Study Pad
 feature state: Android's three search modes, 300 ms content debounce, selector row choice,
 specialized import/export coordination, and route lifetime.

 Data dependencies:
 - SwiftData labels and their Study Pad/bookmark-note relationships
 - reader/workspace `ReaderThemeSurfacePalette`
 - `StudyPadContentSearch` and `AndroidStudyPadArchiveService`

 Side effects:
 - opens a selected Study Pad at an optional first matching entry in the Vue reader
 - commits labels only after the shared full editor saves
 - generates or imports Android `STUDYPAD_EXPORT` archives after explicit confirmation
 - hands completed files to platform-owned Files UI, equivalent to Android intents

 Failure modes:
 - search cancellation drops stale results
 - label, archive, filesystem, and restore failures remain on the route in an app-owned dialog
 - invalid/non-Study-Pad archives are rejected before the shared restore engine applies data
 */
struct StudyPadSelectorView: View {
    /// Small feedback payload rendered by the shared decision dialog.
    private struct Feedback: Equatable {
        let title: String
        let message: String
    }

    /// Shared anchor identities for the two Android popup menus on this activity.
    private enum PopupAnchor {
        static let searchMode = "studyPadSelectorSearchModeAnchor"
        static let overflow = "studyPadSelectorOverflowAnchor"
    }

    /// Reader/workspace-owned palette; no feature-local black/gray palette is allowed.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Active reader workspace forwarded to Android's full label editor.
    let workspace: Workspace?

    /// Current Study Pad label highlighted like Android's active journal row.
    let activeLabelID: UUID?

    /// Reader-owned return action.
    let onDismiss: () -> Void

    /// Vue reader handoff including Android's optional first content-match entry.
    let onOpenStudyPad: (UUID, UUID?) -> Void

    /// SwiftData context used for explicit create/import commits.
    @Environment(\.modelContext) private var modelContext

    /// Current scheme used by shared popup/dialog palette owners.
    @Environment(\.colorScheme) private var colorScheme

    /// Live labels, including Android reserved rows.
    @Query(sort: \BibleCore.Label.name) private var allLabels: [BibleCore.Label]

    /// App-owned search input.
    @State private var searchText = ""

    /// Android-compatible persisted ordinal for selector search mode.
    @AppStorage("labels_list_search_mode") private var persistedSearchModeRawValue =
        StudyPadSelectorSearchMode.nameStart.rawValue

    /// Currently visible shared popup, if any.
    @State private var activePopup: StudyPadSelectorPopup?

    /// Whether filtered canonical Android Help is visible.
    @State private var showsHelp = false

    /// Unsaved new-label editor draft.
    @State private var newLabelDraft: AndroidLabelEditorDraft?

    /// Existing label selected by Android's long-press edit gesture.
    @State private var editingLabelID: UUID?

    /// Shared Study Pad archive state machine used by every Android Manage Labels mode.
    @State private var archiveWorkflow = AndroidStudyPadArchiveWorkflow()

    /// Latest debounced Android content-search results.
    @State private var contentResults: [StudyPadContentSearchResult] = []

    /// Whether a three-character content query is waiting/running.
    @State private var isSearchingContent = false

    /// Explicit refresh generation advanced after archive import.
    @State private var contentSearchRefreshGeneration = 0

    /// App-owned success/failure message.
    @State private var feedback: Feedback?

    /**
     Creates one reader-owned Android Study Pad selector.

     - Parameters:
       - surfacePalette: Active reader/workspace palette.
       - workspace: Active workspace whose label auto-assignment and override fields are edited.
       - activeLabelID: Currently open Study Pad label, if any.
       - onDismiss: Returns to the reader route.
       - onOpenStudyPad: Loads the label and optional first matching entry in Vue.
     - Side effects: none until a user action occurs.
     - Failure modes: none.
     */
    init(
        surfacePalette: ReaderThemeSurfacePalette,
        workspace: Workspace? = nil,
        activeLabelID: UUID?,
        onDismiss: @escaping () -> Void,
        onOpenStudyPad: @escaping (UUID, UUID?) -> Void
    ) {
        self.surfacePalette = surfacePalette
        self.workspace = workspace
        self.activeLabelID = activeLabelID
        self.onDismiss = onDismiss
        self.onOpenStudyPad = onOpenStudyPad
    }

    /// Safe search-mode projection for stale persisted ordinals.
    private var searchMode: StudyPadSelectorSearchMode {
        StudyPadSelectorSearchMode(rawValue: persistedSearchModeRawValue) ?? .nameStart
    }

    /// Android Study Pad selector source: assignable labels except Unlabelled.
    private var selectorLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadSelectorLabels(from: allLabels)
    }

    /// Android export source: every assignable persisted label, including Unlabelled.
    private var exportLabels: [BibleCore.Label] {
        AndroidLabelPresentation.studyPadExportLabels(from: allLabels)
    }

    /// Name-filter rows, or all normal rows below Android's content threshold.
    private var visibleLabels: [BibleCore.Label] {
        let query = searchText
        guard !query.isEmpty else { return selectorLabels }
        switch searchMode {
        case .nameStart:
            return selectorLabels.filter {
                AndroidLabelPresentation.displayName(for: $0).range(
                    of: query,
                    options: [.caseInsensitive, .anchored]
                ) != nil
            }
        case .nameContains:
            return selectorLabels.filter {
                AndroidLabelPresentation.displayName(for: $0).range(of: query, options: [.caseInsensitive]) != nil
            }
        case .content:
            return query.utf16.count < 3 ? selectorLabels : []
        }
    }

    /// Identity used by SwiftUI to cancel stale content-search tasks.
    private var contentSearchIdentity: String {
        let labels = selectorLabels.map { label in
            "\(label.id.uuidString):\(label.studyPadEntries?.count ?? 0):" +
            "\(label.bibleBookmarkToLabels?.count ?? 0):\(label.genericBookmarkToLabels?.count ?? 0)"
        }.joined(separator: "|")
        return "\(searchMode.rawValue)#\(searchText)#\(contentSearchRefreshGeneration)#\(labels)"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidManageLabelsActivityScreen(
                title: String(localized: "studypads", defaultValue: "Study Pads"),
                appBarAccessibilityIdentifier: "studyPadSelectorAppBar",
                surfacePalette: surfacePalette,
                onBack: onDismiss,
                compactModeTitle: searchMode.compactTitle,
                localizedModeTitle: searchMode.localizedTitle,
                isModeActive: searchMode.isVisuallyActive,
                searchText: $searchText,
                accessibilityPrefix: "studyPadSelector",
                popupAnchorID: PopupAnchor.searchMode,
                onSelectSearchMode: { togglePopup(.searchMode) }
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(localized: "new_item", defaultValue: "New"),
                    accessibilityIdentifier: "studyPadSelectorAddButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: beginNewLabel
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("DrawerHelp"),
                    accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                    accessibilityIdentifier: "studyPadSelectorHelpButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: {
                        activePopup = nil
                        showsHelp = true
                    }
                )
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "studyPadSelectorOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor,
                    action: { togglePopup(.overflow) }
                )
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } results: {
                results
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "studypads", defaultValue: "Study Pads"),
                accessibilityIdentifier: "studyPadSelectorScreen",
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .task(id: contentSearchIdentity) {
            await refreshContentResults()
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.searchMode,
            isPresented: popupBinding(.searchMode),
            menuWidth: 280,
            estimatedMenuHeight: 132,
            accessibilityIdentifier: "studyPadSelectorSearchModeMenu"
        ) {
            searchModeMenu
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: popupBinding(.overflow),
            menuWidth: 300,
            estimatedMenuHeight: 88,
            accessibilityIdentifier: "studyPadSelectorOverflowMenu"
        ) {
            overflowMenu
        }
        .overlay { dialogLayer }
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

    /// Normal Android label rows or grouped content-search rows.
    @ViewBuilder
    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if searchMode == .content, searchText.utf16.count >= 3 {
                    ForEach(contentResults) { result in
                        StudyPadSelectorContentResultRow(result: result, surfacePalette: surfacePalette) {
                            onOpenStudyPad(result.labelID, result.matches.first?.entryID)
                        }
                        Divider().overlay(surfacePalette.inactiveBorderColor)
                    }
                } else {
                    ForEach(visibleLabels) { label in
                        StudyPadSelectorLabelRow(
                            label: label,
                            isActive: label.id == activeLabelID,
                            surfacePalette: surfacePalette,
                            onOpen: { onOpenStudyPad(label.id, nil) },
                            onEdit: { editingLabelID = label.id }
                        )
                        Divider().overlay(surfacePalette.inactiveBorderColor)
                    }
                }
            }
        }
        .overlay {
            if isSearchingContent {
                ProgressView()
                    .tint(surfacePalette.foregroundColor)
                    .accessibilityIdentifier("studyPadContentSearchProgress")
            }
        }
    }

    /// Shared popup surface for Android's three search modes.
    private var searchModeMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "studyPadSelectorSearchModeSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            VStack(spacing: 0) {
                ForEach(StudyPadSelectorSearchMode.allCases, id: \.rawValue) { mode in
                    AndroidPopupMenuRow(
                        title: mode.localizedTitle,
                        accessibilityIdentifier: "studyPadSelectorSearchMode::\(mode.rawValue)"
                    ) {
                        persistedSearchModeRawValue = mode.rawValue
                        activePopup = nil
                    }
                }
            }
        }
    }

    /// Shared popup surface for Android's exact Study Pad export/import commands.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "studyPadSelectorOverflowSurface",
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
                    accessibilityIdentifier: "studyPadSelectorExportAction"
                ) {
                    activePopup = nil
                    archiveWorkflow.beginExport()
                }
                AndroidPopupMenuRow(
                    title: String(
                        format: String(localized: "import_items", defaultValue: "Import %@"),
                        String(localized: "studypads", defaultValue: "Study Pads")
                    ),
                    accessibilityIdentifier: "studyPadSelectorImportAction"
                ) {
                    activePopup = nil
                    archiveWorkflow.beginImport()
                }
            }
        }
    }

    /// App-owned feature dialogs and full editor destinations.
    @ViewBuilder
    private var dialogLayer: some View {
        if let newLabelDraft {
            AndroidLabelEditorView(
                draft: newLabelDraft,
                workspace: workspace,
                surfacePalette: surfacePalette,
                onCancel: { self.newLabelDraft = nil }
            )
        } else if let editingLabelID,
                  let label = allLabels.first(where: { $0.id == editingLabelID }) {
            AndroidLabelEditorView(
                label: label,
                workspace: workspace,
                surfacePalette: surfacePalette,
                onClose: { self.editingLabelID = nil }
            )
        } else if showsHelp {
            AndroidHelpDialog(topics: [.studyPads], showsVersion: false) {
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
                        contentSearchRefreshGeneration += 1
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
                accessibilityIdentifier: "studyPadSelectorFeedbackDialog"
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
                accessibilityIdentifier: "studyPadSelectorArchiveFeedbackDialog"
            )
        }
    }

    /// Bridges the selector's mutually exclusive popup enum into the shared presenter binding.
    private func popupBinding(_ popup: StudyPadSelectorPopup) -> Binding<Bool> {
        Binding(
            get: { activePopup == popup },
            set: { isPresented in
                if isPresented {
                    activePopup = popup
                } else if activePopup == popup {
                    activePopup = nil
                }
            }
        )
    }

    /// Toggles exactly one popup and closes any other popup.
    private func togglePopup(_ popup: StudyPadSelectorPopup) {
        activePopup = activePopup == popup ? nil : popup
    }

    /// Creates Android's unsaved full-editor draft with suggested query name and random opaque color.
    private func beginNewLabel() {
        activePopup = nil
        let suggestedName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let red = UInt32.random(in: 0...254)
        let green = UInt32.random(in: 0...254)
        let blue = UInt32.random(in: 0...254)
        let color = Int(Int32(bitPattern: 0xFF000000 | red << 16 | green << 8 | blue))
        newLabelDraft = AndroidLabelEditorDraft(newLabelName: suggestedName, color: color)
    }

    /// Runs Android's cancellable 300 ms three-source content search.
    @MainActor
    private func refreshContentResults() async {
        guard searchMode == .content, searchText.utf16.count >= 3 else {
            isSearchingContent = false
            contentResults = []
            return
        }

        isSearchingContent = true
        contentResults = []
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            let query = searchText
            let documents = StudyPadContentSearch.documents(from: selectorLabels)
            let results = await Task.detached(priority: .userInitiated) {
                StudyPadContentSearch.search(documents: documents, query: query)
            }.value
            try Task.checkCancellation()
            contentResults = results
            isSearchingContent = false
        } catch is CancellationError {
            return
        } catch {
            contentResults = []
            isSearchingContent = false
            feedback = Feedback(
                title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                message: error.localizedDescription
            )
        }
    }

}
