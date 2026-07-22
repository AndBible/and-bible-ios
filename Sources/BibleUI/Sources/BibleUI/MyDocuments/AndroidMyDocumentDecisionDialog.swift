import SwiftUI

/** Renders an Android AlertDialog-equivalent decision without native iOS presentation ownership. */
struct AndroidMyDocumentDecisionDialog: View {
    struct Action: Identifiable {
        enum Style { case normal, destructive }
        let id: String
        let title: String
        let style: Style
        let perform: () -> Void
    }

    let title: String
    let message: String?
    let actions: [Action]

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                if let message, !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    ForEach(actions) { action in
                        Button(role: action.style == .destructive ? .destructive : nil, action: action.perform) {
                            Text(action.title)
                        }
                    }
                }
            }
            .padding(20).frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16)).shadow(radius: 16).padding(24)
        }
        .accessibilityIdentifier("androidMyDocumentDecisionDialog")
    }
}
