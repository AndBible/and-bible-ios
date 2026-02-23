// ShareSheet.swift — Cross-platform share sheet wrapper

import SwiftUI

#if os(iOS)
/// Wraps UIActivityViewController for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
/// Wraps NSSharingServicePicker for SwiftUI on macOS.
struct ShareSheet: View {
    let items: [Any]

    var body: some View {
        VStack(spacing: 12) {
            Text("Share")
                .font(.headline)
            if let text = items.first as? String {
                Text(text)
                    .font(.body)
                    .padding()
                    .textSelection(.enabled)
            }
            Button("Copy to Clipboard") {
                if let text = items.first as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(minWidth: 300)
    }
}
#endif
