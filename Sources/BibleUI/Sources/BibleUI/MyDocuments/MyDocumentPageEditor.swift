// MyDocumentPageEditor.swift -- Android create/rename page dialog

import BibleCore
import SwiftUI

/** Input used by Android's create-page and rename-page dialogs. */
struct MyDocumentPageEditorRequest: Identifiable, Equatable {
    let id = UUID()
    let pageID: UUID?
    let title: String
    let initialTitle: String
    let initialContentType: MyDocumentContentType

    /// Android shows its content-type spinner only while creating a page.
    var allowsContentTypeSelection: Bool { pageID == nil }
}

/**
 Presents Android's page name dialog with the shared app-owned window and popup components.

 Create exposes Android's MARKDOWN/HTML spinner; Rename edits only the page title. Page content is
 opened in the reader and is not replaced by an iOS-only raw-content editor.

 Side effects: mutates transient title/type state and invokes the explicit Save or Cancel closure

 Failure modes: Save remains disabled while the trimmed title is empty
 */
struct MyDocumentPageEditor: View {
    private enum PopupAnchor {
        static let contentType = "myDocumentPageContentTypeAnchor"
    }

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTitleFocused: Bool

    let request: MyDocumentPageEditorRequest
    let onCancel: () -> Void
    let onSave: (String, MyDocumentContentType) -> Void

    @State private var pageTitle: String
    @State private var contentType: MyDocumentContentType
    @State private var showsContentTypeMenu = false

    /** Creates isolated dialog state from one page command. */
    init(
        request: MyDocumentPageEditorRequest,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, MyDocumentContentType) -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onSave = onSave
        _pageTitle = State(initialValue: request.initialTitle)
        _contentType = State(initialValue: request.initialContentType)
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidMyDocumentPageEditorDialog",
            onOutsideTap: onCancel
        ) {
            dialogContent
                .androidAnchoredPopupMenu(
                    anchorID: PopupAnchor.contentType,
                    isPresented: $showsContentTypeMenu,
                    menuWidth: 220,
                    estimatedMenuHeight: 96,
                    accessibilityIdentifier: "myDocumentPageContentTypeMenu"
                ) {
                    contentTypeMenu
                }
        }
    }

    /// Semantic create/rename fields and Android action row.
    private var dialogContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

            AndroidDialogTextInput(
                placeholder: String(localized: "name", defaultValue: "Name"),
                text: $pageTitle,
                colorScheme: colorScheme,
                isMultiline: false,
                accessibilityIdentifier: "myDocumentPageTitleField"
            )
            .focused($isTitleFocused)

            if request.allowsContentTypeSelection {
                AndroidSelectionField(
                    title: String(
                        localized: "my_document_content_type_label",
                        defaultValue: "Content type"
                    ),
                    value: contentType.rawValue,
                    foregroundColor: AndroidDialogSurfacePalette.primaryText(for: colorScheme),
                    secondaryColor: AndroidDialogSurfacePalette.secondaryText(for: colorScheme),
                    backgroundColor: AndroidDialogSurfacePalette.fieldBackground(for: colorScheme),
                    borderColor: AndroidDialogSurfacePalette.fieldBorder(for: colorScheme),
                    accessibilityIdentifier: "myDocumentPageContentTypeButton"
                ) {
                    showsContentTypeMenu.toggle()
                }
                .androidPopupMenuAnchor(id: PopupAnchor.contentType)
            }

            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button(String(localized: "cancel"), action: onCancel)
                    .accessibilityIdentifier("myDocumentPageEditorCancelButton")
                Button(String(localized: "okay", defaultValue: "OK")) {
                    onSave(pageTitle, contentType)
                }
                .disabled(pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("myDocumentPageEditorSaveButton")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        }
        .padding(22)
        .frame(maxWidth: 460)
        .onAppear { isTitleFocused = true }
    }

    /// Shared popup rows for Android's two create-page content types.
    private var contentTypeMenu: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "myDocumentPageContentTypeSurface"
        ) {
            VStack(spacing: 0) {
                ForEach([MyDocumentContentType.markdown, .html], id: \.rawValue) { type in
                    AndroidPopupMenuRow(
                        title: type.rawValue,
                        accessibilityIdentifier: "myDocumentPageContentType::\(type.rawValue)"
                    ) {
                        contentType = type
                        showsContentTypeMenu = false
                    }
                }
            }
        }
    }
}
