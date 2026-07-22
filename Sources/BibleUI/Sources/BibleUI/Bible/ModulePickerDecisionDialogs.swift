import SwiftUI

/** Android-style modal decision surface owned by the module-picker view hierarchy. */
struct ModulePickerDecisionDialog: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        let role: ButtonRole?
        let perform: () -> Void
    }

    let title: String
    let message: String
    let actions: [Action]

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
                HStack { Spacer(); ForEach(actions) { action in
                    Button(role: action.role, action: action.perform) { Text(action.title) }
                } }
            }
            .padding(20).frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidModulePickerDecisionDialog")
    }
}

/** Android-style cipher-key prompt that keeps module unlock state within the picker. */
struct ModulePickerUnlockDialog: View {
    let title: String
    let message: String
    @Binding var cipherKey: String
    let showUnlockInfo: Bool
    let onUnlock: () -> Void
    let onShowUnlockInfo: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
                TextField(String(localized: "passphrase", defaultValue: "Passphrase"), text: $cipherKey)
                    .textFieldStyle(.roundedBorder)
                HStack { Spacer()
                    Button(String(localized: "cancel"), action: onCancel)
                    if showUnlockInfo { Button(String(localized: "show_unlock_info", defaultValue: "Module & unlock info"), action: onShowUnlockInfo) }
                    Button(String(localized: "unlock", defaultValue: "Unlock"), action: onUnlock).disabled(cipherKey.isEmpty)
                }
            }
            .padding(20).frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidModulePickerUnlockDialog")
    }
}
