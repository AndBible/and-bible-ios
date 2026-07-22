import SwiftUI

/**
 Renders Android's in-place new-label AlertDialog above a label owner.

 The caller owns visibility and persistence. This surface only edits the
 transient label name, submits it through ``onCreate``, or clears it when the
dialog is cancelled. It performs no data access and cannot dismiss a reader
or navigation destination through SwiftUI presentation state.
 */
struct AndroidLabelNameDialog: View {
    @Binding var name: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "new_label"))
                    .font(.headline)
                TextField(String(localized: "label_name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("labelManagerNewLabelNameField")
                HStack {
                    Spacer()
                    Button(String(localized: "cancel"), action: onCancel)
                    Button(String(localized: "create"), action: onCreate)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("labelManagerCreateButton")
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidLabelNameDialog")
    }
}
