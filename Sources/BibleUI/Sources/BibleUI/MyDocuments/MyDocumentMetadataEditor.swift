// MyDocumentMetadataEditor.swift -- Android My Documents text-dialog content

import SwiftUI

/** Identifies the exact Android document command represented by one text-entry dialog. */
enum MyDocumentMetadataEditorPurpose: Equatable {
    case create
    case rename(documentID: UUID)
    case editDescription(documentID: UUID)
    case importDocument

    /// Whether Android presents the description field rather than a one-line name field.
    var editsDescription: Bool {
        if case .editDescription = self { return true }
        return false
    }
}

/** Value request presented by the My Documents manager for one Android text-entry command. */
struct MyDocumentMetadataEditorRequest: Identifiable, Equatable {
    let id = UUID()
    let purpose: MyDocumentMetadataEditorPurpose
    let title: String
    let initialValue: String
}

/**
 Edits the one value Android requests for Create, Rename, Edit description, or Import.

 Unlike the previous combined iOS Form, this content does not expose document fields Android did
 not request. The enclosing `AndroidMyDocumentMetadataDialog` owns the shared window and dismissal.
 */
struct MyDocumentMetadataEditor: View {
    let request: MyDocumentMetadataEditorRequest
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isInputFocused: Bool
    @State private var value: String

    /** Creates transient dialog state from the request without mutating the document session. */
    init(
        request: MyDocumentMetadataEditorRequest,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _value = State(initialValue: request.initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))

            AndroidDialogTextInput(
                placeholder: request.purpose.editsDescription
                    ? String(localized: "description", defaultValue: "Description")
                    : String(localized: "name", defaultValue: "Name"),
                text: $value,
                colorScheme: colorScheme,
                isMultiline: request.purpose.editsDescription,
                accessibilityIdentifier: "myDocumentMetadataValueField"
            )
            .focused($isInputFocused)

            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button(String(localized: "cancel"), action: onCancel)
                Button(String(localized: "okay", defaultValue: "OK")) {
                    onSave(value)
                }
                .disabled(!request.purpose.editsDescription && trimmedValue.isEmpty)
                .accessibilityIdentifier("myDocumentMetadataSaveButton")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidDialogSurfacePalette.accent(for: colorScheme))
        }
        .padding(22)
        .frame(maxWidth: 460)
        .onAppear { isInputFocused = true }
    }

    /// Name commands require non-empty trimmed input; descriptions may intentionally be cleared.
    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
