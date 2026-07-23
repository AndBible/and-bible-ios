// AndroidMyDocumentPagesActivityView.swift -- Presentation-only document Pages activity

import BibleCore
import SwiftUI

/**
 Renders Android's complete document Pages activity from caller-owned state and commands.

 The component centralizes the source action bar, empty/list layout, drag affordances, shared popup
 surfaces, and bottom Dismiss/Save bar. The parent retains dialog state, session mutations, transfer
 workflows, persistence, and reader navigation.

 Side effects: mutates only popup bindings and invokes caller commands

 Failure modes: none; the parent owns all fail-visible workflow feedback
 */
struct AndroidMyDocumentPagesActivityView: View {
    private enum PopupAnchor {
        static let overflow = "myDocumentPagesOverflowAnchor"

        static func page(_ id: UUID) -> String {
            "myDocumentPagesRowMenuAnchor::\(id.uuidString)"
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    let document: MyDocumentDraft?
    let pages: [MyDocumentPageDraft]
    let surfacePalette: ReaderThemeSurfacePalette
    let hasChanges: Bool
    let accessibilityValue: String
    @Binding var showsOverflowMenu: Bool
    @Binding var activePageMenuID: UUID?
    let onBack: () -> Void
    let onCreate: () -> Void
    let onImport: () -> Void
    let onDismiss: () -> Void
    let onSave: () -> Void
    let onOpen: (MyDocumentPageDraft) -> Void
    let onRename: (MyDocumentPageDraft) -> Void
    let onExport: (MyDocumentPageDraft) -> Void
    let onDelete: (MyDocumentPageDraft) -> Void
    let onMove: ([String], UUID) -> Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                title: activityTitle,
                accessibilityIdentifier: "myDocumentPagesAppBar",
                palette: surfacePalette,
                onBack: onBack
            ) {
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ActivityAddCircle"),
                    accessibilityLabel: String(
                        localized: "my_document_create_page_title",
                        defaultValue: "New page"
                    ),
                    accessibilityIdentifier: "myDocumentPagesAddButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    closePopups()
                    onCreate()
                }
                AndroidActivityTopAppBarActionButton(
                    icon: .asset("ToolbarOverflow"),
                    accessibilityLabel: String(localized: "system_items1", defaultValue: "More"),
                    accessibilityIdentifier: "myDocumentPagesOverflowButton",
                    foregroundColor: surfacePalette.toolbarForegroundColor
                ) {
                    activePageMenuID = nil
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
                        isCommitEnabled: hasChanges,
                        accessibilityPrefix: "myDocumentPages",
                        onDismiss: onDismiss,
                        onCommit: onSave
                    )
                }
            }

            AndroidActivityAccessibilityMarker(
                label: activityTitle,
                accessibilityIdentifier: "myDocumentPagesScreen",
                accessibilityValue: accessibilityValue,
                surfaceColor: surfacePalette.backgroundColor
            )
        }
        .androidAnchoredPopupMenu(
            anchorID: PopupAnchor.overflow,
            isPresented: $showsOverflowMenu,
            menuWidth: 280,
            estimatedMenuHeight: 54,
            accessibilityIdentifier: "myDocumentPagesOverflowMenu"
        ) { overflowMenu }
        .androidAnchoredPopupMenu(
            anchorID: activePageMenuID.map(PopupAnchor.page) ?? "",
            isPresented: pageMenuBinding,
            menuWidth: 250,
            estimatedMenuHeight: 156,
            accessibilityIdentifier: "myDocumentPagesRowMenu"
        ) { pageMenu }
    }

    /// Android's missing, empty, or flat draggable page content.
    @ViewBuilder
    private var content: some View {
        if document == nil {
            emptyMessage(String(
                localized: "error_key_not_in_document",
                defaultValue: "Not found in document"
            ))
        } else if pages.isEmpty {
            emptyMessage(String(
                localized: "my_document_pages_empty",
                defaultValue: "No pages in this document."
            ))
        } else if let document {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        AndroidMyDocumentManagementRow(
                            title: page.title,
                            subtitle: page.contentType.rawValue,
                            showsAIIndicator: page.sourcePromptId != nil,
                            dragPayload: page.id.uuidString,
                            menuAnchorID: PopupAnchor.page(page.id),
                            surfacePalette: surfacePalette,
                            accessibilityIdentifier: rowIdentifier(page, document: document),
                            accessibilityValue: "pageKey=\(page.pageKey);contentType=\(page.contentType.rawValue)",
                            onOpen: { onOpen(page) },
                            onShowMenu: { showPageMenu(page.id) }
                        )
                        .dropDestination(for: String.self) { payloads, _ in onMove(payloads, page.id) }
                        Divider().overlay(surfacePalette.inactiveBorderColor)
                    }
                }
            }
        }
    }

    private var overflowMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "myDocumentPagesOverflowSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            AndroidPopupMenuRow(
                title: String(
                    localized: "my_document_import_page",
                    defaultValue: "Import Markdown/HTML"
                ),
                accessibilityIdentifier: "myDocumentPagesImportAction"
            ) {
                showsOverflowMenu = false
                onImport()
            }
        }
    }

    @ViewBuilder
    private var pageMenu: some View {
        if let page = activePageMenuID.flatMap({ id in pages.first { $0.id == id } }) {
            AndroidPopupMenuSurface(
                colorScheme: colorScheme,
                accessibilityIdentifier: "myDocumentPagesRowMenuSurface",
                backgroundColor: surfacePalette.backgroundColor,
                primaryTextColor: surfacePalette.foregroundColor,
                secondaryTextColor: surfacePalette.secondaryForegroundColor,
                accentColor: surfacePalette.controlAccentColor
            ) {
                VStack(spacing: 0) {
                    popupRow(String(localized: "rename"), identifier: "myDocumentPagesRenameAction") {
                        onRename(page)
                    }
                    popupRow(String(localized: "export"), identifier: "myDocumentPagesExportAction") {
                        onExport(page)
                    }
                    popupRow(String(localized: "delete"), identifier: "myDocumentPagesDeleteAction") {
                        onDelete(page)
                    }
                }
            }
        }
    }

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

    private var activityTitle: String {
        guard let document else {
            return String(localized: "my_documents_title", defaultValue: "My Documents")
        }
        return String(
            format: String(localized: "my_document_pages_title", defaultValue: "%@ - Pages"),
            document.name
        )
    }

    private var pageMenuBinding: Binding<Bool> {
        Binding(
            get: { activePageMenuID != nil },
            set: { if !$0 { activePageMenuID = nil } }
        )
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 17))
            .foregroundStyle(surfacePalette.secondaryForegroundColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    private func showPageMenu(_ pageID: UUID) {
        showsOverflowMenu = false
        activePageMenuID = activePageMenuID == pageID ? nil : pageID
    }

    private func closePopups() {
        showsOverflowMenu = false
        activePageMenuID = nil
    }

    private func rowIdentifier(
        _ page: MyDocumentPageDraft,
        document: MyDocumentDraft
    ) -> String {
        "myDocumentsPageRow::\(myDocumentsAccessibilitySegment(document.initials))::\(myDocumentsAccessibilitySegment(page.pageKey))"
    }
}
