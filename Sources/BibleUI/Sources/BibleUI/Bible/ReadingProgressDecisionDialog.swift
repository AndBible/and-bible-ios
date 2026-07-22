import SwiftUI

/** App-owned Android-style decision surface for Reading Progress actions and feedback. */
struct ReadingProgressDecisionDialog: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        let perform: () -> Void
    }

    let title: String
    let message: String
    let actions: [Action]

    var body: some View {
        ZStack {
            Color.black.opacity(0.36).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                if !title.isEmpty { Text(title).font(.headline) }
                Text(message).foregroundStyle(.secondary)
                HStack { Spacer(); ForEach(actions) { action in Button(action.title, action: action.perform) } }
            }
            .padding(20).frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityIdentifier("androidReadingProgressDecisionDialog")
    }
}
