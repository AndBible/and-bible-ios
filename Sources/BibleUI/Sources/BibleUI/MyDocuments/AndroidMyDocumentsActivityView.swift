// AndroidMyDocumentsActivityView.swift -- Presentation-only My Documents activity

import BibleCore
import SwiftUI

/**
 Renders Android's complete My Documents activity from caller-owned state and commands.

 This component owns only activity chrome, rows, popup placement, empty-state layout, and bottom
 actions. The parent remains the sole owner of draft mutations, file handoffs, dialogs, persistence,
 and reader navigation, preventing presentation parity from creating a second workflow controller.

 Inputs: ordered draft documents, owner palette, dirty state, popup bindings, and explicit commands

 Output: one app-owned Android activity presentation

 Side effects: mutates popup bindings and invokes only caller-supplied commands

 Failure modes: none; command failures are rendered by the parent dialog layer
 */
struct AndroidMyDocumentsActivityView: View {
    private enum PopupAnchor {
        static let overflow = "myDocumentsOverflowAnchor"

        static func document(_ id: UUID) -> String {
            "myDocumentsDocumentMenuAnchor::\(id.uuidString)"
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    let documents: [MyDocumentDraft]
    let surfacePalette: ReaderThemeSurfacePalette
    let isDirty: Bool
    let accessibilityValue: String
    @Binding var showsOverflowMenu: Bool
    @Binding var activeDocumentMenuID: UUID?
    let onBack: () -> Void
    let onCreate: () -> Void
    let onImport: () -> Void
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onOpen: (UUID) -> Void
    let onRename: (MyDocumentDraft) -> Void
    let onEditDescription: (MyDocumentDraft) -> Void
    let onExport: (MyDocumentDraft) -> Void
    let onDelete: (MyDocumentDraft) -> Void
    let onMove: ([String], UUID) -> Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: String(localized: "my_documents_title", defaultValue: "My Documents"),
                accessibilityIdentifier: "myDocumentsAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(
                        localized: "my_document_create_title",
                        defaultValue: "Create new document"
                    ),
                    accessibilityIdentifier: "myDocumentsAddButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    closePopups()
                    onCreate()
                }
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "myDocumentsOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    activeDocumentMenuID = nil
                    showsOverflowMenu.toggle()
                }
                .androidPopupMenuAnchor(id: PopupAnchor.overflow)
            } content: {
                VStack(spacing: 0) {
                    content
                    AndroidActivityCommitBar(
                        dismissTitle: String(localized: "dismiss", defaultValue: "Dismiss"),
                        commitTitle: String(localized: "save_and_exit", defaultValue: "Save"),
                        backgroundColor: surfacePalette.backgroundColor,
                        accentColor: AndroidDialogSurfacePalette.accent(for: colorScheme),
                        disabledColor: surfacePalette.disabledForegroundColor,
                        isCommitEnabled: isDirty,
                        accessibilityPrefix: "myDocuments",
                        onDismiss: onDismiss,
                        onCommit: onSave
                    )
                }
            }

            AndroidActivityAccessibilityMarker(
                label: String(localized: "my_documents_title", defaultValue: "My Documents"),
                accessibilityIdentifier: "myDocumentsListScreen",
                accessibilityValue: accessibilityValue,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 310,
            estimatedMenuHeight: 54,
            accessibilityIdentifier: "myDocumentsOverflowMenu"
        ) {
            overflowMenu
        }
        .androidAnchoredPopupMenu(
            anchorID: activeDocumentMenuID.map(PopupAnchor.document) ?? "",
            isPresented: documentMenuBinding,
            menuWidth: 280,
            estimatedMenuHeight: 208,
            accessibilityIdentifier: "myDocumentsDocumentMenu"
        ) {
            documentMenu
        }
    }

    /// Android's text-only empty state or flat draggable rows.
    @ViewBuilder
    private var content: some View {
        if documents.isEmpty {
            Text(String(
                localized: "my_documents_empty",
                defaultValue: "No documents yet. Tap + to create one."
            ))
            .font(.system(size: 17))
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(documents) { document in
                        AndroidMyDocumentManagementRow(
                            title: document.name,
                            subtitle: descriptionText(document),
                            showsAIIndicator: document.sourcePromptId != nil,
                            dragPayload: document.id.uuidString,
                            menuAnchorID: PopupAnchor.document(document.id),
                            surfacePalette: surfacePalette,
                            accessibilityIdentifier: documentRowIdentifier(document),
                            accessibilityValue: "initials=\(document.initials);pages=\(document.pages.count)",
                            onOpen: { onOpen(document.id) },
                            onShowMenu: { showDocumentMenu(document.id) }
                        )
                        .dropDestination(for: String.self) { payloads, _ in
                            onMove(payloads, document.id)
                        }
                        Divider().overlay(surfacePalette.inactiveBorderColor)
                    }
                }
            }
        }
    }

    /// Android overflow has exactly one Import command.
    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "myDocumentsOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            AndroidPopupMenuRow(
                title: String(
                    localized: "my_document_import_document",
                    defaultValue: "Import files as document"
                ),
                accessibilityIdentifier: "myDocumentsImportAction"
            ) {
                showsOverflowMenu = false
                onImport()
            }
        }
    }

    /// Android row popup preserves source order and contains no invented icons.
    @ViewBuilder
    private var documentMenu: some View {
        if let document = activeDocumentMenuID.flatMap({ id in documents.first { $0.id == id } }) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "myDocumentsDocumentMenuSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(spacing: 0) {
                    popupRow(String(localized: "rename"), identifier: "myDocumentsRenameAction") {
                        onRename(document)
                    }
                    popupRow(
                        String(
                            localized: "my_document_edit_description",
                            defaultValue: "Edit description"
                        ),
                        identifier: "myDocumentsEditDescriptionAction"
                    ) { onEditDescription(document) }
                    popupRow(
                        String(
                            localized: "my_document_export_document",
                            defaultValue: "Export all pages"
                        ),
                        identifier: "myDocumentsExportAction"
                    ) { onExport(document) }
                    popupRow(String(localized: "delete"), identifier: "myDocumentsDeleteAction") {
                        onDelete(document)
                    }
                }
            }
        }
    }

    /** Builds one row and clears popup ownership before invoking its command. */
    private func popupRow(
        _ title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidPopupMenuRow(
            title: title,
            accessibilityIdentifier: identifier
        ) {
            closePopups()
            action()
        }
    }

    private var documentMenuBinding: Binding<Bool> {
        Binding(
            get: { activeDocumentMenuID != nil },
            set: { if !$0 { activeDocumentMenuID = nil } }
        )
    }

    private func showDocumentMenu(_ documentID: UUID) {
        showsOverflowMenu = false
        activeDocumentMenuID = activeDocumentMenuID == documentID ? nil : documentID
    }

    private func closePopups() {
        showsOverflowMenu = false
        activeDocumentMenuID = nil
    }

    private func descriptionText(_ document: MyDocumentDraft) -> String {
        guard let description = document.documentDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return String(localized: "my_document_no_description", defaultValue: "No description")
        }
        return description
    }

    private func documentRowIdentifier(_ document: MyDocumentDraft) -> String {
        "myDocumentsDocumentRow::\(myDocumentsAccessibilitySegment(document.initials))"
    }
}
