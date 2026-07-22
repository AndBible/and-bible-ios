import SwiftUI

/**
 Renders Android's Help & Tips dialog as an app-owned reader window.

 Android opens Help in place instead of navigating to an adaptive sheet. This wrapper preserves the
 existing localized help content and version footer while giving it an explicit dialog lifetime and
 close action.
 */
struct AndroidHelpDialog: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            NavigationStack {
                HelpView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "ok", defaultValue: "OK"), action: onDismiss)
                        }
                    }
            }
            .frame(maxWidth: 640, maxHeight: 700)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 16)
            .padding(24)
        }
        .accessibilityIdentifier("androidHelpDialog")
    }
}
