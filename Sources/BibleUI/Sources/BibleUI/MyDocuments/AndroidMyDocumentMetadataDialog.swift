import SwiftUI

/** Android AlertDialog-equivalent owner for My Documents name and description editing. */
struct AndroidMyDocumentMetadataDialog: View {
    let request: MyDocumentMetadataEditorRequest
    let onDismiss: () -> Void
    let onSave: (String, String?) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            MyDocumentMetadataEditor(
                request: request,
                onSave: onSave,
                onCancel: onDismiss
            )
            .frame(maxWidth: 560, maxHeight: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidMyDocumentMetadataDialog")
    }
}
